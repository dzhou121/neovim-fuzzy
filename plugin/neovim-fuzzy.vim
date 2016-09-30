"
" neovim-fuzzy
"
" Author:       Alexis Sellier <http://cloudhead.io>
" Version:      0.1
"
if exists("g:loaded_fuzzy") || &cp || !has('nvim')
  finish
endif
let g:loaded_fuzzy = 1

if !exists("g:fuzzy_opencmd")
  let g:fuzzy_opencmd = 'edit'
endif

let s:fuzzy_job_id = 0
let s:fuzzy_prev_window = -1
let s:fuzzy_prev_window_height = -1
let s:fuzzy_bufnr = -1
let s:fuzzy_source = {}
let s:fuzzy_lines = 40

function! s:fuzzy_err_noexec()
  throw "Fuzzy: no search executable was found. " .
      \ "Please make sure either '" .  s:ag.path .
      \ "' or '" . s:rg.path . "' are in your path"
endfunction

" Methods to be replaced by an actual implementation.
function! s:fuzzy_source.find(il) dict
  call s:fuzzy_err_noexec()
endfunction

function! s:fuzzy_source.find_contents() dict
  call s:fuzzy_err_noexec()
endfunction

"
" ag (the silver searcher)
"
let s:ag = { 'path': 'ag' }

function! s:ag.find(root, ignorelist) dict
  let ignorefile = tempname()
  call writefile(a:ignorelist, ignorefile, 'w')
  return systemlist(
    \ "ag --silent --nocolor -g '' -Q --path-to-ignore " . ignorefile . ' ' . a:root)
endfunction

function! s:ag.find_contents(query) dict
  let query = empty(a:query) ? '^(?=.)' : a:query
  return systemlist("ag --noheading --nogroup --nocolor -S " . shellescape(query) . " .")
endfunction

"
" rg (ripgrep)
"
let s:rg = { 'path': 'rg' }

function! s:rg.find(root, ignorelist) dict
  let ignores = []
  for str in a:ignorelist
    call add(ignores, printf("-g '!%s'", str))
  endfor
  return systemlist("rg --color never --files --fixed-strings " . join(ignores, ' ') . ' ' . a:root)
endfunction

function! s:rg.find_contents(query) dict
  let query = empty(a:query) ? '.' : shellescape(a:query)
  return systemlist("rg -n --no-heading --color never -S " . query . " .")
endfunction

" Set the finder based on available binaries.
if executable(s:rg.path)
  let s:fuzzy_source = s:rg
elseif executable(s:ag.path)
  let s:fuzzy_source = s:ag
endif

command! -nargs=? FuzzyGrep   call s:fuzzy_grep(<q-args>)
command! -nargs=? FuzzyOpen   call s:fuzzy_open(<q-args>)
command!          FuzzyBlines call s:fuzzy_blines()
command!          FuzzyFiles  call s:fuzzy_files()
command!          FuzzyKill   call s:fuzzy_kill()

autocmd FileType fuzzy tnoremap <buffer> <Esc> <C-\><C-n>:FuzzyKill<CR>

function! s:fuzzy_kill()
  echo
  call jobstop(s:fuzzy_job_id)
endfunction

function! s:buffer_lines()
  return map(getline(1, "$"),
    \ 'printf("%4d %s", v:key + 1, v:val)')
endfunction

function! s:fuzzy_blines()
  let contents = s:buffer_lines()
  let opts = { 'lines': s:fuzzy_lines, 'statusfmt': 'FuzzyBlines (%d results)' }
  function! opts.handler(result) abort
    let parts = split(join(a:result), ' ')
    let lnum = parts[0]

    return { 'lnum': lnum }
  endfunction

  return s:fuzzy(contents, opts)
endfunction

function! s:fuzzy_files()
  let contents = ''
  let opts = { 'lines': s:fuzzy_lines, 'statusfmt': 'FuzzyFiles (%d results)', 'cmd': 'python ~/dotfiles/find.py | fzy'}
  function! opts.handler(result) abort
    let parts = split(join(a:result), '  ')
    let name = parts[1]
    return { 'name': fnameescape(name) }
  endfunction

  return s:fuzzy(contents, opts)
endfunction

function! s:fuzzy_grep(str) abort
  try
    let contents = s:fuzzy_source.find_contents(a:str)
  catch
    echoerr v:exception
    return
  endtry

  let opts = { 'lines': s:fuzzy_lines, 'statusfmt': 'FuzzyBlines (%d results)' }
  function! opts.handler(result) abort
    let parts = split(join(a:result), ':')
    let name = parts[0]
    let lnum = parts[1]
    let text = parts[2] " Not used.

    return { 'name': name, 'lnum': lnum }
  endfunction

  return s:fuzzy(contents, opts)
endfunction

function! s:fuzzy_open(root) abort
  " Get open buffers.
  let bufs = filter(range(1, bufnr('$')),
    \ 'buflisted(v:val) && bufnr("%") != v:val && bufnr("#") != v:val')
  let bufs = map(bufs, 'bufname(v:val)')
  call reverse(bufs)

  " Add the '#' buffer at the head of the list.
  if bufnr('#') > 0 && bufnr('%') != bufnr('#')
    call insert(bufs, bufname('#'))
  endif

  " Save a list of files the find command should ignore.
  let ignorelist = !empty(bufname('%')) ? bufs + [bufname('%')] : bufs

  " Get all files, minus the open buffers.
  try
    let files = s:fuzzy_source.find(a:root, ignorelist)
  catch
    echoerr v:exception
    return
  endtry

  " Put it all together.
  let result = bufs + files

  let opts = { 'lines': s:fuzzy_lines, 'statusfmt': 'FuzzyOpen (%d files)' }
  function! opts.handler(result)
    return { 'name': join(a:result) }
  endfunction

  return s:fuzzy(result, opts)
endfunction

function! s:fuzzy(choices, opts) abort
  let outputs = tempname()

  if !executable('fzy')
    echoerr "Fuzzy: the executable 'fzy' was not found in your path"
    return
  endif

  " Clear the command line.
  echo

  let cmd = "fzy"
  if has_key(a:opts, 'cmd')
    let cmd = a:opts.cmd
  endif

  let command = cmd . " -l " . a:opts.lines . " > " . outputs

  let type = type(a:choices)
  if type == 3
    let inputs = tempname()
    call writefile(a:choices, inputs)
    let command = command . " < " . inputs
  endif

  let opts = { 'outputs': outputs, 'handler': a:opts.handler }

  function! opts.on_exit(id, code) abort
    " NOTE: The order of these operations is important: Doing the delete first
    " would leave an empty buffer in netrw. Doing the resize first would break
    " the height of other splits below it.
    call win_gotoid(s:fuzzy_prev_window)
    exe 'silent' 'bdelete!' s:fuzzy_bufnr
    exe 'resize' s:fuzzy_prev_window_height

    if a:code != 0 || !filereadable(self.outputs)
      return
    endif

    let result = readfile(self.outputs)
    if !empty(result)
      let file = self.handler(result)
      if has_key(file, 'name')
        silent execute g:fuzzy_opencmd fnameescape(file.name)
      endif
      if has_key(file, 'lnum')
        silent execute file.lnum
        normal! zz
      endif
    endif
  endfunction

  let s:fuzzy_prev_window = win_getid()
  let s:fuzzy_prev_window_height = winheight('%')

  if bufnr(s:fuzzy_bufnr) > 0
    exe 'keepalt' 'below' a:opts.lines . 'sp' bufname(s:fuzzy_bufnr)
  else
    exe 'keepalt' 'below' a:opts.lines . 'new'
    let s:fuzzy_job_id = termopen(command, opts)
    let b:fuzzy_status = printf(a:opts.statusfmt, len(a:choices))
    setlocal statusline=%{b:fuzzy_status}
  endif
  let s:fuzzy_bufnr = bufnr('%')
  set filetype=fuzzy
  startinsert
endfunction

