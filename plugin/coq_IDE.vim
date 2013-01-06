" Document {{{
" Copyright: Copyright (C) 2012 Matthieu Carlier
" Last Change:  2012 January 6
"
" Filename: coq_IDE.vim
" Author:   Matthieu Carlier <matthieu.carlier@caramail.fr>
" URL:      Soon ?
" $revision: 0.91b$
"
" License: CeCILL-C V1
"
" Description:
" You can use this script to make vim behaves like CoqIDE
"
" Installation:
" Copy this file to "~/.vim/ftplugin/coq_IDE.vim".
"
" Prerequisite:
" This plugin requires +perl support in vim and need coq version >=8.4beta
" available on $PATH.
"
" Configuration:
" Nothing to be done when "coqtop.opt" is accessible via PATH variable.
" Otherwise you can specify it by adding
" 'let coqtop = "/path/to/exe/my_cmd"' in your "~/.vimrc".
"
" Usage:
" Open a .v file.
" Use these commands to send/rewind command to coqtop :
"  - IDEUndo         Rewind last command (may rewind more than one command)
"  - IDENext         Send next command to coqtop
"  - IDEToCursor     Send all commands through cursor position (not included)
"  - IDEUndoAll      Rewind all commands
"  - IDEToEOF        Send all commands through the end of file
"  - IDERefresh      Refresh the windows Goals and Informations and center cursor on current command
"  - IDEKill         Kill coqtop
"
" You can also use the following default key binding :
"    <F2> -> IDEUndo
"    <F3> -> IDENext
"    <F4> -> IDEToCursor
"    <F5> -> IDEUndoAll
"    <F6> -> IDEToEOF
"    <F7> -> IDERefresh     
"    <F8> -> IDEKill
"
" To break a long computation type 'b'
"
" Known Bugs:
"  - the script could be wrong on guessing where the buffer is modified (see ActionOccured())
"  - breaking computation (by pressing 'b') only works on terminal (see ugly hack in s:ReadCoqTop())
"  - :redraw doesn't work on MacVim GUI. What about gvim ?
"
" History:
"   2012-09-01
"     Add support for '-', '+', '*', '{' and '}' in proof
"     Now comments are treated as separated command
"
"   2012-05-24
"     Initial version is created
" }}}

if exists('coqtop')
  let s:coqtop = coqtop
else
  let s:coqtop = 'coqtop.opt'
endif

if exists('g:loaded_CoqIDE')
  finish
endif
let g:loaded_CoqIDE = 1

if !has('perl')
  echoerr "Your vim doesn't supports perl. Install it before using CoqIde mode."
  finish
endif

if executable(s:coqtop) < 1
  echoerr s:coqtop . ': command not found.'
  finish
endif

let s:refreshcount = 100 " When processing a bunch of commands refresh the screen
                         " every s:refreshcount sent commands.

" Prelude {{{
" XML Queries Syntax :
" <call val="interp" [raw=("true|"false")] [verbose=("true"|"false")]>COQ_INSTRUCTION</call>
" <call val="rewind" steps="nb"></call>
" <call val="goal"></call>
" <call val="setoptions"><pair><list><string>Printing</string><string>Notations</string></list><option_value val="boolvalue"><bool val="false"/></option_value></pair></call>
" </call>
"
" <list><string>Printing</string><string>Notation</string></list>
" To be continued...
"
" Variables :
"
" b:lastquery        : last XML query
" b:lastresponse     : last XML response
" b:lastquerykind    : kind of last query
"
" b:coqhistory       : list of all commands sent to coqtop
" b:nbstep           : number of command register to coqhistory
" b:nbsent           : number of command sent to coqtop
" b:curline b:curcol : position a last character sent
" b:tcol, b:tline    : position of the character to send
"
" b:coqtop_pid       : pid of running coqtop
" b:mychangedtick    : number of change since opening of buffer
" b:init             : the script has been initialized
" b:info             : text to be printed on Informations buffer (string list)
"

""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
"
" Global definitions

function s:Debug(category, msg)
  "if a:category == 'UpdateColor'
  "if a:category == 'NextPosN'
  "if a:category == 'info_undo'
  "if a:category == 'info_history' || a:category == 'info_undo'
  "  echomsg a:msg
  "endif
endfunction

"""""""""""""""""""""""""""""""
"""""""""""""""""""""""""""""""
"""""""""""""""""""""""""""""""
"
" History manipulation
"

function s:ResetHistory()
  let b:coqhistory = []
  let b:nbstep = 0
  let b:nbsent = 0
  let b:lastquerykind = ''

  " For debugging :
  let b:queryhistory = []
  let b:responsehistory = []
  let b:lastquery = ''
  let b:lastresponse = ''
  let b:lastgoalresponse = ''
endfunction

function s:AddToHistory(bline, bcol, eline, ecol, sent)
  if a:sent
    let b:nbsent = b:nbsent + 1 
  endif

  if len(b:coqhistory) <= b:nbstep
    call add(b:coqhistory, [a:bline, a:bcol, a:eline, a:ecol, b:nbsent, a:sent])
  else
    let b:coqhistory[b:nbstep] = [a:bline, a:bcol, a:eline, a:ecol, b:nbsent, a:sent]
  endif

  let b:nbstep = b:nbstep + 1
endfunction

function HistorySentIdx(sent)
  call s:Debug('info_history', 'HistorySentIdx: a:sent = ' . a:sent)
  let l:found = 0
  let l:cur = a:sent - 1

  while(!l:found && l:cur + 1 < b:nbstep) 
    call s:Debug('info_history', 'HistorySentIdx: historyidx[' . (l:cur + 1) . '] = ' . b:coqhistory[l:cur + 1][4])
    if b:coqhistory[l:cur + 1 ][4] == a:sent + 1
      let l:found = 1
    endif
    let l:cur = l:cur + 1
  endwhile

  call s:Debug('info_history', 'HistorySentIdx: return ' . l:cur)
  return l:cur
endfunction

" Get the number of the command sent to coqtop which contains the position
" [nline, ncol]. A comment is consider as part of the command just after it.
"
" -1 if not found
function s:GetStep(nline, ncol)
  let l:min = 0
  let l:max = b:nbstep - 1

  let l:found = 0

  while(! l:found && l:min <= l:max)
    let l:cur = (l:min + l:max) / 2
    let [l:bline, l:bcol, l:eline, l:ecol, _, _ ] = b:coqhistory[l:cur]

    if a:nline < l:bline || a:nline == l:bline && a:ncol <= l:bcol
      let l:max = l:cur - 1
    elseif l:eline < a:nline || l:eline == a:nline && l:ecol < a:ncol
      let l:min = l:cur + 1
    else
      let l:found = 1
    endif
  endwhile

  if l:found
    return l:cur + 1
  endif

  return -1
endfunction

"""""""""""""""""""""""""""""""
"""""""""""""""""""""""""""""""
"""""""""""""""""""""""""""""""

" Takes two cursor positions [(nlines, ncol1)] and [(nline2, ncol2)].
" Returns the position nearest the beginning of the file.
" If one position is defined as the invalid position [0, 0], returns
" the other
function s:GetLowest(nline1, ncol1, nline2, ncol2)
  if (a:nline1 == 0 && a:ncol1 == 0)
    return [a:nline2, a:ncol2]
  endif

  if (a:nline2 == 0 && a:ncol2 == 0)
    return [a:nline1, a:ncol1]
  endif

  if a:nline1 < a:nline2 || (a:nline1 == a:nline2 && a:ncol1 < a:ncol2)
    return [a:nline1, a:ncol1]
  endif

  return [a:nline2, a:ncol2]
endfunction

" From a position [(l, c)], returns the position of the next character.
" It doesn't check whether EOF is encountered.
function s:NextPos(l, c)
  if (a:c < strlen(getline(a:l)))
    return [a:l, a:c + 1]
  endif

  return [a:l + 1, 1]
endfunction

function s:NextPosN(l, c, n)
  call s:Debug('NextPosN', '>>> NextPosN(' . a:l . ', ' . a:c . ', ' . a:n . ')')
  if a:l == 0 && a:c == 0
    let l:curline = 1
    let l:targetcol = a:n
  else
    let l:curline = a:l
    let l:targetcol = a:n + a:c
  endif

  let l:last = line('$')

  let l:found = 0
  while(! (l:found || l:last < l:curline))
    call s:Debug('NextPosN', '--- NextPosN : l:curline = ' . l:curline . ', l:targetcol = ' . l:targetcol)
    let l:curlen = strlen(getline(l:curline))

    if l:targetcol <= l:curlen
      let l:found = 1
    else
      let l:curline += 1
      let l:targetcol = l:targetcol - l:curlen - 1
    endif

  endwhile

  if l:found
    call s:Debug('NextPosN', '<<< NextPosN() -> [' . l:curline . ', ' . l:targetcol . ']')
    return [l:curline, l:targetcol]
  endif

  call s:Debug('NextPosN', '<<< NextPosN() -> EOF')
  return [0, 0]

endfunction

" From position [(line, col)], returns the position of the next '.'.
" Do not check whether the '.' is inside a comment
function s:NextDot(line, col)

  " a dot could be either at end of a line or inner a line
  call cursor(a:line, a:col)
  let [l:nline1, l:ncol1] = searchpos('\.$', 'cW')
  call cursor(a:line, a:col)
  let [l:nline2, l:ncol2] = searchpos('\.\s', 'cW')

  return s:GetLowest(l:nline1, l:ncol1, l:nline2, l:ncol2)
endfunction

function s:RedrawCenter()
  call s:SetColorTarget()
  call s:UpdateBufColor()
  call s:SetCursorAfterInterp()
  redraw!
endfunction

""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
"
" The functions for setting colors
"
"
highlight SentToCoq ctermbg=LightGreen guibg=LightGreen
highlight WillSendToCoq ctermbg=Yellow guibg=Yellow
highlight link CoqTopError Error

function s:PatLine(cmp, nb)
  return '\%' . a:cmp . a:nb . 'l'
endfunction

function s:PatCol(cmp, nb)
  return '\%' . a:cmp . a:nb . 'c'
endfunction

function s:PatBlock(bline, bcol, eline, ecol)
  if a:eline == a:bline
    " Color only one line :
    return s:PatLine('', a:bline) . s:PatCol('>', a:bcol - 1) . s:PatCol('<', a:ecol + 1) . '[^$]'
  endif

  " Color a bunch of line :
  let l:pattern =           s:PatLine('', a:bline)  . (a:bcol == 0?'':s:PatCol('>', a:bcol - 1)) . '[^$]'
  let l:pattern .=  '\|' .  s:PatLine('>', a:bline) . s:PatLine('<', a:eline)   . '[^$]'
  let l:pattern .=  '\|' .  s:PatLine('', a:eline)  . s:PatCol('<', a:ecol + 1) . '[^$]'
  return l:pattern
endfunction

" 1. Change color of the lines from beginning of the buffer to [nline], [ncol]
" 2. Set the global variable [b:curline] and [b:curcol] to [nline] and
" [ncol]

function s:UnsetColorSent()
  if exists('w:clinesent') && w:clinesent != -1
    call matchdelete(w:clinesent)
    let w:clinesent = -1
  endif
 "syntax clear SentToCoq
endfunction

function s:SetColorSent()
  call s:UnsetColorSent()
  let w:clinesent = matchadd('SentToCoq', s:PatLine('<', b:curline) . '[^$]' . '\|' .  s:PatLine('', b:curline) . s:PatCol('<', b:curcol + 1) . '[^$]', 5)
  "execute 'syntax match SentToCoq contains=TOP "' . s:PatLine('<', b:curline) . '[^$]' . '\|' . s:PatLine('', b:curline) . s:PatCol('<', b:curcol + 1) . '[^$]"'
endfunction

function s:SetLastPositionSent(nline, ncol)
  let b:curline = a:nline
  let b:curcol = a:ncol
endfunction

function s:UnsetColorTarget()
  if exists('w:clinetarget')
    call matchdelete(w:clinetarget)
    unlet w:clinetarget
    let [b:tline, b:tcol] = [0, 0]
  endif
endfunction

function s:SetColorTarget()
  if b:tline == 0 && b:tcol == 0
    return
  endif

  let [l:sline, l:scol] = s:NextPos(b:curline, b:curcol)

  if exists('w:clinetarget')
    call matchdelete(w:clinetarget)
  endif
  let w:clinetarget = matchadd('WillSendToCoq', s:PatBlock(l:sline , l:scol, b:tline, b:tcol))
endfunction

function s:SetTarget(line, col)
  let b:tline = a:line
  let b:tcol = a:col
endfunction

" The error handles (w:error variable) :

function s:UnsetColorError()
  if exists('w:cerror') && w:cerror != -1
    call matchdelete(w:cerror)
    let w:cerror = -1
  endif
  "syntax clear CoqTopError
endfunction

" Color in red the character number a:start to number a:end. 0 is the last
" position sent to coqtop.
function s:SetColorError(start, end)
  " sometimes a:end is before a:start
  " Sometimes (a:start= '58', a:end = '102') vim does not convert the string
  " into an int correctly so we add a 0 :
  let [l:start, l:end] = (a:start <= a:end)?[a:start, a:end]:[a:end, a:start]
  call s:UnsetColorError()

  let [l:sline, l:scol] = s:NextPosN(b:curline, b:curcol, l:start + 1)
  if l:sline == 0 && l:scol == 0
    return
  endif

  let [l:eline, l:ecol] = s:NextPosN(l:sline, l:scol, l:end - l:start - 1)
  if l:eline == 0 && l:ecol == 0
    return
  endif

  let w:cerror = matchadd('CoqTopError', s:PatBlock(l:sline, l:scol, l:eline, l:ecol))
  call cursor(l:sline, l:scol)
  normal zz
endfunction

" The two last functions are needed for simulating "buffer specific"
" matchadd() on ColorSent.

" Update the "sent" color on all windows displaying current buffer.
function s:UpdateBufColor()
  call s:Debug('UpdateBufColor', '>>> UpdateBufColor()')
  let l:bcur = bufnr('%')
  let l:wcur = winnr()
  let l:allbuf = tabpagebuflist()
  let l:i = 0
  while l:i < len(l:allbuf)
     if l:allbuf[l:i] == l:bcur
       execute (l:i + 1) . 'wincmd w'
       call s:SetColorSent()
     endif
     let l:i = l:i + 1
   endwhile
  execute l:wcur . 'wincmd w'
  call s:Debug('UpdateBufColor', '<<< UpdateBufColor() -> Ok')
endfunction

" Update the "sent" color on all windows (called when the tab changed)
function UpdateColor()
  if exists('s:in_script')
    return
  endif

  call s:Debug('UpdateColor', '>>> UpdateColor()')
  let l:savpos = getpos('.')

  let l:allbuf = tabpagebuflist()
  let l:i = 0
  "echomsg string(l:allbuf)
  while l:i < len(l:allbuf)
    if bufname(l:allbuf[l:i]) =~# '.*\.v'
      execute (l:i + 1) . 'wincmd w'
      call s:SetColorSent()
    endif
    let l:i = l:i + 1
  endwhile

  call setpos('.', l:savpos)
  call s:Debug('UpdateColor', '<<< UpdateColor()')
endfunction

""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
"
" }}}

" coqtop: lauching/sending messages/receiving messages {{{
" Functions manipulating coqtop process

" kill coqtop process if any. The already_dead argument indicates coqtop was
" killed by an exterior event (kill -9 in the command line for example) or
" crash ("Check 1234567891011121314%nat." for example)

function KillCoqtop(already_dead)
  if exists('b:coqtop_pid') && b:coqtop_pid != 0
    if a:already_dead == 0
      :perl kill(9, VIM::Eval('b:coqtop_pid'));
    endif
    :perl waitpid(VIM::Eval('b:coqtop_pid'), 0);
    :perl close($coqoutput[VIM::Eval("bufnr('%')")]);
    :perl close($coqinput[VIM::Eval("bufnr('%')")]);
    unlet b:coqtop_pid
    call s:SetLastPositionSent(0, 0)
    call s:UpdateBufColor()
    call s:UnsetColorError()
    call s:UnsetColorTarget()
    call s:HideGoalsErrorBuffers()
  endif
endfunction

function s:BreakComputation()
  :perl kill(SIGINT, VIM::Eval('b:coqtop_pid'));
endfunction

" Launch coqtop. If coqtop is already launched and force is 0 do nothing
" otherwise kill a potential coqtop process and launch another instance.
function s:LaunchCoqtop(force)
  if (exists('b:coqtop_pid') && b:coqtop_pid != 0 && a:force == 0)
    return 1
  endif

  call KillCoqtop(0)

  :perl <<EOF
  use FileHandle;

  local $RVim = new FileHandle;
  local $WVim = new FileHandle;

  pipe(RCoq, $WVim);
  pipe($RVim, WCoq);

  my $valret = 0;

  my $pid = fork;
  if ($pid == 0)
  {
    close($WVim);
    close($RVim);
    open(\*STDIN, '<&RCoq');
    open(\*STDOUT, '>&WCoq');
    exec(VIM::Eval('s:coqtop') . ' -ideslave');
    exit;
  }

  if(defined $pid)
  { $valret = 1; }

  close(WCoq);
  close(RCoq);

  # autoflush on write in $WVim :
  $tmp = select($WVim);
  $| = 1;

  # Set RVim and WVim in a global table so they don't be disallocated (and closed)
  $coqoutput[VIM::Eval("bufnr('%')")] = $WVim;
  $coqinput[VIM::Eval("bufnr('%')")] = $RVim;

  VIM::DoCommand('let b:coqtop_pid=' . $pid);
  VIM::DoCommand('let valret= '. $valret);
EOF

  call s:Debug('info', 'coqtop pid = ' . b:coqtop_pid)

  call s:SetLastPositionSent(0, 0)
  call s:UpdateBufColor()
  call s:ResetHistory()
  call s:UnsetColorTarget()
  call s:UnsetColorError()

  return valret
endfunction

" Send the string s to coqtop
function WriteCoqTop(s)
  :perl <<EOF
  $s = VIM::Eval('a:s');
  $OUT = $coqoutput[VIM::Eval("bufnr('%')")];
  print $OUT $s;
EOF
endfunction

" Read an XML tree from the filehandler coqtop outputs it responses. This
" function blocks until a complete tree is read.
function s:ReadAnXMLTree()
:perl <<EOF
  $IN = $coqinput[VIM::Eval("bufnr('%')")];
  my ($prev, $depth, $init, $addonclose, $tree);
  $addonclose = 0;
  $prev = 'a';
  $init = 0;
  $depth = 0;
  $tree="";

  while (($init == 0 || $depth != 0 ) && read($IN, $cur, 1) != 0)
  {
    $tree = $tree . $cur;

    if($prev eq '<')
    {
       if($cur eq '/')
       { $addonclose = -1; }
       else
       { $addonclose = 1; }
    }
    elsif($prev eq '/' && $cur eq '>')
    { $addonclose = 0; }
    else
    {
      if($addonclose != 0 && $cur eq '>')
      {
        $init = 1;
        $depth = $depth + $addonclose;
        $addonclose = 0;
      }
    }

    $prev = $cur;
  }

  VIM::DoCommand("let l:ret_value = '${tree}'");
EOF
  return l:ret_value
endfunction

" Read last coqtop xml response. This function should by preceded by a call to
" WriteCoqTop()
function s:ReadCoqTop(interrupt)
  let line = ""

  " When we are authorized to interrupt computation, wait for either user pressed
  " 'b' or coq has finished it computations.
:perl <<EOF
  $IN = $coqinput[VIM::Eval("bufnr('%')")];

  $both = '';
  $killed = 0;
  if(VIM::Eval('a:interrupt') != 0)
  {
    $coq_ready = 0;
    while(!$killed && !$coq_ready)
    {
      vec($both,fileno($IN), 1) = 1;
      vec($both,fileno(STDIN), 1) = 1;
      select($both, undef, undef, undef);
      if(vec($both, fileno(STDIN), 1) == 1 &&
         sysread(STDIN, $char, 1) == 1 && $char eq 'b')
      {
        $killed = 1;
        kill(SIGINT, VIM::Eval('b:coqtop_pid'));
      }
      elsif(vec($both, fileno($IN), 1) == 1)
      {
         $coq_ready = 1;
      }
    }
  }

  VIM::DoCommand('let l:killed = ' . $killed);
EOF
  let l:raw_resp = s:ReadAnXMLTree()

  " There is a tiny probability (i.e. depending on OS scheduler) coqtop answer
  " arrives after we detect a 'b' from the user and before coqtop receives the
  " SIGINT signal. In such a case, coqtop postpones the treatment of the
  " signal. This signal is treated when the next command is sent and coqtop
  " answers "User interrupt".

  if raw_resp == ''
    throw 'broken_pipe'
  endif
  return raw_resp
endfunction

" Position the cursor just after the last interpreted command.
function s:SetCursorAfterInterp()
    let [l:nline, l:ncol] = s:NextPos(b:curline, b:curcol)
    call cursor(l:nline, l:ncol)
    normal z.
endfunction

" }}}

""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
"
" Create XML queries and send/receive it

" Send/receive XML queries {{{

""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
"
" Three functions for 'pseudo XML' parsing

function s:XML_unescape(s)
  let l:s = substitute(a:s, '&gt;', '>', 'g')
  let l:s = substitute(l:s, '&lt;', '<', 'g')
  let l:s = substitute(l:s, '&apos;', "'", 'g')
  let l:s = substitute(l:s, '&quot;', '"', 'g')
  let l:s = substitute(l:s, '&amp;', '\&', 'g')

  return l:s
endfunction

function s:XML_decode_goal(s)
  if a:s == ''
    return []
  endif
  if match(a:s, '</list>') != -1
    " at least one hypothesis
    let [_, l:tmp1, l:goal, _, _, _, _, _, _, _] = matchlist(a:s, '^.*<list>\(.*\)</list><string>\(.*\)</string>$')
    let l:tmp2 = split(substitute(l:tmp1, '^<string>\(.*\)</string>$', '\1', ''), '</string><string>')
    let l:hyps = []
    for l:hyp in l:tmp2
      let l:hyps += split(l:hyp, '\n')
    endfor
  else
    " no hypothesis
    let l:hyps = []
    let [_, l:goal, _, _, _, _, _, _, _, _] = matchlist(a:s, '^<list/><string>\(.*\)</string>$')
  endif

  call map(l:hyps, 's:XML_unescape(v:val)')
  return [l:hyps, split(s:XML_unescape(l:goal), '\n')]
endfunction

" XML Format of input :
"
" <option val="some | none">
"   <goals>
"     <list>
"       <goal>
"         GOAL
"       </goal>
"       ...
"     </list>
"     <list>
"       <pair>
"         <list>
"           ...
"         </list>
"         <list>
"           ...
"         </list>
"       </pair>
"     </list>
"   </goals>
" </option>

function s:XML_decode_goals(s)
  if a:s =~# '^<option val="none"/>'
    return [[],[]]
  endif
  " some(...)

  " For avoiding bad surprises :
  let l:raw_resp = substitute(a:s, '<list/>', '<list></list>', 'g')

  let l:raw_resp = substitute(l:raw_resp, '^<option val="[^"]*"><goals>\(.*\)</goals></option>$', '\1', '')
  let [_, l:fg, l:bg, _, _, _, _, _, _, _] = matchlist(l:raw_resp, '^<list>\(.\{-}\)</list><list>\(.*\)</list>$')

  let l:fg_goal_list = split(substitute(l:fg, '^<goal>\(.*\)</goal>$', '\1', ''), '</goal><goal>')
  call map(l:fg_goal_list, 's:XML_decode_goal(v:val)')

  
  let l:bg_goal_list = split(substitute(l:bg, '^<goal>\(.*\)</goal>$', '\1', ''), '</goal><goal>')
"  call map(l:bg_goal_list, 's:XML_decode_goal(v:val)')

  return [l:fg_goal_list, l:bg_goal_list]
endfunction

function s:SendCommand(type, opt, s)

  if a:type == 'interp'

    " substitutions for XML syntax compliance
    let l:s = ""
    let pos = 0

    while (pos < strlen(a:s))
      let l:s = l:s . (a:s[pos] == '&' && a:s[pos+1] != '\#'?'&amp;':a:s[pos])
      let pos += 1
    endwhile

    let l:s = substitute(l:s, '>', '\&gt;', 'g')
    let l:s = substitute(l:s, '<', '\&lt;', 'g')
    let l:s = substitute(l:s, "'", '\&apos;', 'g')
    let l:s = substitute(l:s, '"', '\&quot;', 'g')

    let l:query = '<call val="interp">' . l:s . '</call>'
    let b:lastquerykind = 'interp'
    let b:lastquery = l:query
  elseif a:type == 'rewind'
    let l:query = '<call val="rewind" steps="' . a:opt . '"></call>'
    let b:lastquerykind = 'rewind'
    let b:lastquery = l:query
  elseif a:type == 'setoptions'

    let l:i = 0
    let l:args = ''

    while(l:i < len(a:opt))
      let l:args .= '<string>' . a:opt[l:i] . '</string>'
      let l:i = l:i + 1
    endwhile

    let l:query = '<call val="setoptions"><pair><list>' . l:args . '</list><option_value val="boolvalue"><bool val="' . a:s . '"/></option_value></pair></call>'
    let b:lastquerykind = 'setoptions'
  else
    let l:query = '<call val="goal"></call>'
    let b:lastquerykind = 'goal'
  endif

  let b:queryhistory += [l:query]

  call s:Debug('XML', l:query)

  call WriteCoqTop(l:query)
endfunction

function s:GetResponse(interrupt)
  let l:rawresp = s:ReadCoqTop(a:interrupt)

  if b:lastquerykind == 'goal'
    let b:lastgoalresponse = l:rawresp
  else
    let b:lastresponse = l:rawresp
  endif
  let b:responsehistory += [l:rawresp]
  let l:verdict = substitute(l:rawresp, '^<value val="\([^"]*\)"[^>]*>.*$', '\1', '')
  let l:resp = substitute(l:rawresp, '^<value val="[^"]*"[^>]*>\(.*\)</value>$', '\1', '')

  call s:Debug('XML', l:rawresp)

  if l:verdict == 'fail'
    if match(l:rawresp, '^<[^>]*loc_s') != -1
      let l:loc_s = substitute(l:rawresp, '^<value[^>]*loc_s="\([^"]*\)".*$', '\1', '')
      let l:loc_e = substitute(l:rawresp, '^<value[^>]*loc_e="\([^"]*\)".*$', '\1', '')
      let b:info = split(s:XML_unescape(l:resp), '\n')
      throw 'fail(' . l:loc_s . ',' . l:loc_e . ')'
    else
      let b:info = split(s:XML_unescape(l:resp), '\n')
      throw 'fail'
    endif
  endif

  if b:lastquerykind == 'goal'
    return ['goal', s:XML_decode_goals(l:resp)]
  endif

  if l:resp == ''
    return ['void', ['']]
  endif

  let l:string_resp = substitute(l:resp, '^<string>\(.*\)</string>$', '\1', '')
  if strlen(l:string_resp) != strlen(l:resp)
    return ['string', split(s:XML_unescape(l:string_resp), '\n')]
  endif

  let l:int_resp = substitute(l:resp, '^<int>\(.*\)</int>$', '\1', '')
  if strlen(l:int_resp) != strlen(l:resp)
    return ['int', l:int_resp]
  endif

  return ['unkown', [l:resp]]
endfunction

""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
"
" Functions changing loaded lines

" A rather complex function. Determines the end position of the next command.
" It searches for a '.' followed by a space outside comments and returns the
" command together with the found position. Afterward, the beginning of the
" next command is given by [b:curline] and [b:curcol].
"
" If end of file is detected, throw "eof" exception

" 
" call searchpos('\(\_$\|\_s\)*\*')
" 
" 

function GetPart(bline, bcol, eline, ecol)
  let l:cmd = getline(a:bline, a:eline)

  " We should delete the beginning of first matched line and the end of the
  " last matched line according to b:curcol and l:dcol.
  let l:cmd[-1] = strpart(l:cmd[-1],0, a:ecol)
  let l:cmd[0] = strpart(l:cmd[0], a:bcol)

  let l:result = ""
  for l:str in l:cmd
    let l:result = l:result . l:str . "\n"
  endfor

  return l:result
endfunction

function s:GetNextCmd()
  let [l:npl, l:npc] = s:NextPos(b:curline, b:curcol)

  " First of all search for either '*', '+', '-', '{' or '}' just at the
  " beginning of the command.
  
  call cursor(b:curline, b:curcol)
  let [l:cline, l:ccol] = searchpos('\_s*\%(\*\|+\|-\|{\|}\)', 'cW')
  if l:cline == b:curline && l:ccol == b:curcol + 1
    call cursor(b:curline, b:curcol)
    let [l:dline, l:dcol] = searchpos('\%(\*\|+\|-\|{\|}\)', 'cW')

    return [GetPart(b:curline, b:curcol, l:dline, l:dcol), l:dline, l:dcol, 1]
  endif

  " Search whether the next non-blank characters are (* :
  "
  call cursor(b:curline, b:curcol)
  let [l:cline, l:ccol] = searchpos('\_s*(\*', 'cW')
  if l:cline == b:curline && l:ccol == b:curcol + 1
    call searchpos('(\*', 'cW')
    let [l:dline, l:dcol] = searchpairpos('(\*', '', '\*)', 'W')

    return [GetPart(b:curline, b:curcol, l:dline, l:dcol + 1), l:dline, l:dcol + 1, 0]
  endif

  " Then Search for a '.' outside comments
  let l:found = 0
  let l:eof = 0
  let l:dline = l:npl
  let l:dcol = l:npc

  if getline(l:dline, l:dline) == []
    let l:eof = 1
  endif

  while(! (l:found || l:eof))
    call cursor(l:dline, l:dcol)
    let [l:cline, l:ccol] = searchpos('(\*', 'cW')
    let [l:dline, l:dcol] = s:NextDot(l:dline, l:dcol)

    call s:Debug('infonextdot', '"(*" found at ' . l:cline . ', ' . l:ccol)
    call s:Debug('infonextdot', '"." found at ' . l:dline . ', ' . l:dcol)

    if l:dline == 0 && l:dcol == 0
      let l:eof = 1 " Could be either EOF or the last command has no '.' at its end.
    endif

    if l:cline == 0 && l:ccol == 0 || (l:dline < l:cline || l:dline == l:cline && l:dcol < l:ccol)
      " Next comment begin after the next '.' (or no comment) so things are OK
      let l:found = 1
    else
      " Else move the cursor to the end of the comment
      call cursor(l:cline, l:ccol)
      let [l:dline, l:dcol] = searchpairpos('(\*', '', '\*)', 'W')
      call s:Debug('infonextdot', '"*)" found at ' . l:dline . ', ' . l:dcol)

      if l:dline == 0 && l:dcol == 0
        let l:eof = 1
      endif
    endif
  endwhile

  if l:eof == 1
    throw 'eof'
  endif

  call s:Debug('infonextdot', 'Next dot is at ' . l:dline . ', ' . l:dcol)

  return [GetPart(b:curline, b:curcol, l:dline, l:dcol), l:dline, l:dcol, 1]
endfunction

" }}}

" Goal/informations buffers {{{

" Set the syntax color for goals on current buffer
function s:AddSyntaxColor()
  syntax clear
  syntax case match
  syntax keyword goalKwd else end exists2 fix forall fun if in struct then match with let as Set Prop Type fix struct exists where
  syntax match   goalSymb "|\|/\\\|\\/\|<->\|\~\|->\|=>\|{\|}\|&\|+\|-\|*\|=\|>\|<\|<=\|:=\|(\|)\|:"
  syntax match goalbar '=='
  syntax match hypName "^[a-z'_.A-Z0-9]* \?:\&[a-z'_.A-Z0-9]*"
  syntax match header "^[0-9]* subgoals\?"
  highlight default link goalSymb Type
  highlight default link goalKwd  Type
  highlight default link goalbar  Keyword
  highlight default link header   Keyword
  highlight default link hypName  Preproc
endfunction

" Create two new buffers 'Goals', 'Informations' and
" display both in two windows
" If the buffers already exists, display them
function s:ShowGoalsErrorBuffers()

  let l:wgoal = exists('s:bgoals')?bufwinnr(s:bgoals):-1
  let l:winfo = exists('s:berror')?bufwinnr(s:berror):-1

  if l:wgoal != 1 && l:winfo != -1
    return
  elseif l:wgoal == -1 && l:winfo != -1
    execute s:berror . 'wincmd w'
    execute 'silent aboveleft new Goals'
    return
  elseif l:wgoal != -1 && l:winfo == -1
    execute s:bgoals . 'wincmd w'
    execute 'silent belowright new Informations'
    return
  endif

  let l:winsave = winnr()

  " The window were the goals are displayed :
  execute 'silent rightbelow vnew Goals'
  if exists('s:bgoals')
    execute 'silent buffer ' . s:bgoals
  else
    setlocal bufhidden=hide
    setlocal scrolloff=0
    setlocal buftype=nofile
    setlocal noswapfile
    let s:bgoals = bufnr('%')
    silent normal gg"_dG
    call s:AddSyntaxColor()
  endif

  " The window were the errors are displayed :
  execute 'silent rightbelow new Informations'
  if exists('s:berror')
    execute 'silent buffer ' . s:berror
  else
    setlocal bufhidden=hide
    setlocal buftype=nofile
    setlocal scrolloff=0
    setlocal noswapfile
    let s:berror = bufnr('%')
    silent normal gg"_dG
    call s:AddSyntaxColor()
  endif

  execute l:winsave . 'wincmd w'
endfunction

" Hide both buffers 'Goals', 'Informations'
function s:HideGoalsErrorBuffers()
  let l:winsave = winnr()

  let l:allbuf = tabpagebuflist()
  let l:i = 0
  while l:i < len(l:allbuf)
     if l:allbuf[l:i] == s:berror
       execute (l:i + 1) . 'wincmd w'
       execute ':q'
     endif

     if l:allbuf[l:i] == s:bgoals
       execute (l:i + 1) . 'wincmd w'
       execute ':q'
     endif
     let l:i = l:i + 1
   endwhile

  execute l:winsave . 'wincmd w'
endfunction

" Go to s:berror buffer in current window and replace its content by a:info
function s:ShowInfo(info)
  execute 'sbuffer ' . s:berror
  silent normal gg"_dG
  call append(0, a:info)
  normal gg
endfunction

" Go to s:berror buffer in current window and replace its content by goals given in a:fgbg
function s:ShowGoals(fgbg)
  let [l:fg, l:bg] = a:fgbg

  execute 'sbuffer ' . s:bgoals
  silent normal gg"_dG

  if l:fg == []
    return
  endif

  let [l:hyps, l:goal] = l:fg[0]
  let l:nbgoal = len(l:fg)

  if len(l:fg) == 1
    call append(0, '1 subgoal')
  else
    call append(0, len(l:fg) . ' subgoals')
  endif
  call append(1, l:hyps)
  let l:count = 1 + len(l:hyps)
  call append(l:count, '====================================================================== (1/' . l:nbgoal . ')')
  call append(l:count + 1, l:goal)
  normal kmaj
  let l:count += 1 + len(l:goal)
  let l:gnb = 2
  for l:remaingoal in l:fg[1:-1]
    let [_, l:goal] = l:remaingoal
    call append(l:count, ['', '====================================================================== (' . l:gnb . '/' . l:nbgoal . ')'])
    call append(l:count + 2, l:goal)
    let l:gnb += 1
    let l:count += 2 + len(l:goal)
  endfor

  normal 'azb

endfunction

function s:ShowGoalsInfo()
  call s:Debug('ShowGoalsInfo', '>>> ShowGoalsInfo()')
  " Get current goals :
  try
    call s:SendCommand('goal', '', '')
    let [_, l:fgbg] = s:GetResponse(0)
  catch /fail.*/
    let l:fgbg = [[], []]
    return -1
  endtry

  let l:info = b:info

  let l:winsave = winnr()
  let l:saveswb = &switchbuf
  execute 'set switchbuf=useopen'

  " Ensure 'Goals' and 'Informations' buffers are associated to a window
  " Then displays the values on each buffer
  call s:ShowGoalsErrorBuffers()
  call s:ShowInfo(l:info)
  call s:ShowGoals(l:fgbg)

  execute 'set switchbuf = ' . l:saveswb
  execute l:winsave . 'wincmd w'
  call s:Debug('ShowGoalsInfo', '<<< ShowGoalsInfo()')
endfunction

" }}}
"
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Send/rewind commands {{{

" Four functions for sending commands or undoing.
" they return :
" '2' when all is OK
" '1' when we decide to finish the process (no command sent)
" '0' when eof encountered (no command sent)
" '-1' when the command fails
" '-2' when the command fails and the cause is highlighted in red
" raise broken_pipe when coqtop has been killed

" [tline, tcol] : do not send when the next command contains this position.
function s:SendNextCmd(tline, tcol)
  try
    let [l:s, l:nline, l:ncol, l:tobesent] = s:GetNextCmd()
    if a:tline != 0 && a:tcol != 0 && (a:tline < l:nline || a:tline == l:nline && a:tcol <= l:ncol)
      return 1
    endif
    call s:Debug('info', 'End of command  at : ' . l:nline . ', ' . l:ncol)
    if l:tobesent
      call s:SendCommand('interp', '', l:s)
      let [_, b:info] = s:GetResponse(1)
    endif
  catch /eof/
    return 0
  catch /^fail$/
    return -1
  catch /^fail(.*)$/
    let l:loc_s = substitute(v:exception, '^fail(\(.*\),.*)$', '\1', '')
    let l:loc_e = substitute(v:exception, '^fail(.*,\(.*\))$', '\1', '')
    call s:SetColorError(l:loc_s + 0, l:loc_e + 0) " force int conversion
    return -2
  endtry

  call s:AddToHistory(b:curline, b:curcol, l:nline, l:ncol, l:tobesent)
  call s:SetLastPositionSent(l:nline, l:ncol)

  return 2
endfunction

" Same, but purposes to be called once (it handles target color)
function s:SendOneCmd()
  call s:Debug('SendOneCmd', '>>> SendOneCmd()')
  try
    let l:savpos = getpos('.')
    let [l:s, l:nline, l:ncol, l:tobesent] = s:GetNextCmd()
    call s:SetTarget(l:nline, l:ncol)
    if l:tobesent
      call s:SetColorTarget()
      call setpos('.', l:savpos) | redraw
      call s:SendCommand('interp', '', l:s)
      let [_, b:info] = s:GetResponse(1)
    endif
  catch /eof/
    call s:Debug('SendOneCmd', '<<< SendOneCmd() -> 0 (EOF)')
    return 0
  catch /^fail$/
    call s:UnsetColorTarget()
    call s:Debug('SendOneCmd', '<<< SendOneCmd() -> -1 (Fail)')
    return -1
  catch /^fail(.*)$/
    call s:UnsetColorTarget()
    let l:loc_s = substitute(v:exception, '^fail(\(.*\),.*)$', '\1', '')
    let l:loc_e = substitute(v:exception, '^fail(.*,\(.*\))$', '\1', '')
    call s:SetColorError(l:loc_s + 0, l:loc_e + 0) " Force int conversion
    call s:Debug('SendOneCmd', '<<< SendOneCmd() -> -2 (Fail)')
    return -2
  endtry

  call s:UnsetColorTarget()
  call s:AddToHistory(b:curline, b:curcol, l:nline, l:ncol, l:tobesent)
  call s:SetLastPositionSent(l:nline, l:ncol)

  call s:Debug('SendOneCmd', '<<< SendOneCmd() -> 2 (Ok)')
  return 2
endfunction

" Undo commands until it reaches at least the step number [nb].
" Remarks:
"  - coqtop can decide to undo more command (for example, when undoing a 'Qed',
"     all the proof is undo)
"  - this function does not change cursor position (even temporarily)
function s:UndoTo(nb)
  call s:Debug('info_undo', 'Goto step ' . a:nb . ' with nbstep = ' . b:nbstep . ' nbsent = ' . b:nbsent)

  if b:nbstep == 0 || a:nb == b:nbstep
    call s:Debug('info_undo', 'Goto step ' . a:nb . ': no step to rewind')
    return 1
  endif

  let l:targetsent = (a:nb < 1)?0:(b:coqhistory[a:nb - 1][4])
  let l:nbrewind = (a:nb < 1)?(b:nbsent):(b:nbsent - l:targetsent)

  if l:nbrewind == 0
    let b:nbstep = a:nb
    let [_, _, l:nline, l:ncol, _, _] = b:coqhistory[b:nbstep - 1]
    call s:SetLastPositionSent(l:nline, l:ncol)
    call s:UpdateBufColor()
    call s:Debug('info_undo', 'Goto step ' . a:nb . ': rewind a comment')
    return 2
  endif

  try
    call s:SendCommand('rewind', l:nbrewind, '')
    let [l:type, l:extrarewind] = s:GetResponse(0)
  catch /^fail$/ " the other fail is unlikely to happen
    return -1
  endtry

  let b:nbsent = l:targetsent - l:extrarewind
  let b:nbstep = (l:extrarewind == 0)?(a:nb):HistorySentIdx(l:targetsent - l:extrarewind)
  if b:nbstep == 0
    let [l:nline, l:ncol] = [0, 0]
  else
    let [_, _, l:nline, l:ncol, _, _] = b:coqhistory[b:nbstep - 1]
  endif
  call s:SetLastPositionSent(l:nline, l:ncol)
  call s:UpdateBufColor()
  call s:Debug('info_undo', 'Goto step: rewind = ' . l:nbrewind . ' extrarewind = ' . l:extrarewind . ' nbstep = ' . b:nbstep . ' nbsent = ' . b:nbsent)

  return 2
endfunction

function s:SendCmdUntilPos(nline, ncol)
  call s:Debug('info_untilcursor', 's:SendCmdUntilPos()')

  if b:curline < a:nline || (b:curline == a:nline && b:curcol < a:ncol)
    " Cursor is after the last sent command
    call s:SetTarget(a:nline, a:ncol)
    call s:SetColorTarget()
    redraw
    call s:Debug('info_untilpos', 'b:curline(' . b:curline . ') < a:nline(' . a:nline . ')')
    let l:count = 0
    let l:resSend = s:SendNextCmd(a:nline, a:ncol)
    while(b:curline < a:nline && l:resSend == 2)
      let l:count = l:count + 1
      if l:count == s:refreshcount
        call s:RedrawCenter()
        let l:count = 0
      endif
      let l:resSend = s:SendNextCmd(a:nline, a:ncol)
    endwhile

    call s:UnsetColorTarget()
    return l:resSend
  endif
  " Cursor is before or inner the last sent command
  call s:Debug('info_untilpos', 'a:nline(' . a:nline . ') <= b:curline(' . b:curline . ')')
  return s:UndoTo(s:GetStep(a:nline, a:ncol) - 1)
endfunction

""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
"
" Extra functions that are written in term of above defined function

function s:UndoSteps(nbstep)
  return s:UndoTo(b:nbstep - a:nbstep)
endfunction

function s:UndoToPos(line, col)
  if a:line < b:curline || a:line == b:curline && a:col <= b:curcol
    try
      return s:UndoTo(s:GetStep(a:line, a:col) - 1)
    catch /^broken_pipe$/
      call PipeIsBroken()
      return -1
    endtry
  endif
  return 1
endfunction

function s:ProceedUntilCursor()
  let [_, l:cline, l:ccol, _] = getpos('.')
  return s:SendCmdUntilPos(l:cline, l:ccol)
endfunction

function s:ProceedUntilEnd()
  call s:SetTarget(line('$') + 1, 6)
  call s:SetColorTarget()
  redraw

  let l:count = 0
  let l:resSend = s:SendNextCmd(0, 0)
  while(l:resSend == 2)
    let l:count = l:count + 1
    if l:count == s:refreshcount
      call s:RedrawCenter()
      let l:count = 0
    endif
    let l:resSend = s:SendNextCmd(0, 0)
  endwhile

  call s:UnsetColorTarget()
  return l:resSend
endfunction

function SetOption(num, b)
  if a:num == 0
    let l:opt = ['Printing', 'Implicit']
    let l:desc = 'notation'
  elseif a:num == 1
    let l:opt = ['Printing', 'Coercions']
    let l:desc = 'coercions'
  elseif a:num == 2
    let l:opt = ['Printing', 'Matching', 'Synth']
    let l:desc = 'raw matching expressions'
  elseif a:num == 3
    let l:opt = ['Printing', 'Notations']
    let l:desc = 'notations'
  elseif a:num == 4
    let l:opt = ['Printing', 'All']
    let l:desc = 'all low-level contents'
  elseif a:num == 5
    let l:opt = ['Printing', 'Existential', 'Instances']
    let l:desc = 'existential variable instances'
  else
    let l:opt = ['Printing', 'Universes']
    let l:desc = 'universe levels'
  endif

  try
    call s:SendCommand('setoptions', l:opt, (a:b?'true':'false'))
    call s:GetResponse(0)
  catch /fail.*/ " Should never arrive
    let l:winsave = winnr()
    let l:saveswb = &switchbuf
    execute 'set switchbuf=useopen'
    call s:ShowGoalsErrorBuffers()
    call s:ShowInfo(b:info)
    execute 'set switchbuf = ' . l:saveswb
    execute l:winsave . 'wincmd w'
    return -1
  endtry

  echomsg (a:b?'Set':'Unset') . ' printing ' . l:desc
endfunction

" }}}

""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" All the rest of the file defines IHM
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

" Key binding {{{

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Take the result of "send command to coq" and decide whether we restore cursor
" position or move the cursor after the last command sent or do nothing
"
" Recall :
" -3 -> broken_pipe
" -2 -> fail with pos
" -1 -> fail
"  0 -> eof
"  1 -> the command doesn't sent anthing to coqtop
"  2 -> no problem

function s:MoveOrRestoreCursor(resSend, savecur)
  let [_, l:cline, l:ccol, _] = a:savecur
  if a:resSend == -2
    return
  elseif a:resSend == -1 || l:cline < b:curline || l:cline == b:curline && l:ccol < b:curcol
    call s:SetCursorAfterInterp()
  elseif a:resSend != 0
    call setpos('.', a:savecur)
  endif
endfunction

function PipeIsBroken()
  call s:SetCursorAfterInterp()
  " TODO: Set the color of this incriminated command in red ?
  call KillCoqtop(1)
  let l:winsave = winnr()
  let l:saveswb = &switchbuf
  execute 'set switchbuf=useopen'
  call s:ShowGoalsErrorBuffers()
  call s:ShowInfo(['Error: coqtop suddenly quit.'])
  execute 'set switchbuf = ' . l:saveswb
  execute l:winsave . 'wincmd w'
  call s:UpdateBufColor()
endfunction

" Wrapper for all functionalities
function ExecCmd(cmd)
  call s:Debug('ExecCmd', '>>> ExecCmd()')
  if bufname('%') !~# '.*\.v'
    echomsg 'The current buffer is not a Coq source file'
    call s:Debug('ExecCmd', '<<< ExecCmd() -> Not a source')
    return
  endif

  if !s:LaunchCoqtop(0)
    echomsg 'Impossible to launch coqtop'
    call s:Debug('ExecCmd', '<<< ExecCmd() -> NoCoq')
    return
  endif

  let s:in_script = 1

  try
    let l:savecur = getpos('.')

    if a:cmd == 0
      let resCoqtop = s:SendOneCmd()
    elseif a:cmd == 1 
      let resCoqtop = s:ProceedUntilCursor()
    elseif a:cmd == 2 
      let resCoqtop = s:UndoSteps(1)
    elseif a:cmd == 3 
      let resCoqtop = s:UndoSteps(b:nbstep)
    elseif a:cmd == 4 
      let resCoqtop = s:ProceedUntilEnd()
    else
      let resCoqtop = s:ShowGoalsErrorBuffers()
      call s:SetCursorAfterInterp()
    endif

    call s:MoveOrRestoreCursor(l:resCoqtop, l:savecur)
    call s:ShowGoalsInfo()
    call s:UpdateBufColor()
  catch /^broken_pipe$/
    call PipeIsBroken()
  endtry
  unlet s:in_script
  call s:Debug('ExecCmd', '<<< ExecCmd()')
endfunction

" The commands for the user :
function s:SetNewCommand()
  command -bar -buffer IDENext         :call ExecCmd(0)
  command -bar -buffer IDEToCursor     :call ExecCmd(1)
  command -bar -buffer IDEUndo         :call ExecCmd(2)
  command -bar -buffer IDEUndoAll      :call ExecCmd(3)
  command -bar -buffer IDEToEOF        :call ExecCmd(4)
  command -bar -buffer IDERefresh      :call ExecCmd(5)
  command -bar -buffer IDEKill         :call KillCoqtop(0) | echomsg 'coqtop killed'
"  command -buffer IDEBreak    :call s:BreakComputation()
endfunction

" Map the commands to <F2>-<F6>
function s:SetMapKey()
  nmap <buffer> <silent> <F2> :<C-U>IDEUndo<CR>
  imap <buffer> <silent> <F2> <ESC>:IDEUndo<CR>

  nmap <buffer> <silent> <F3> :<C-U>IDENext<CR>
  imap <buffer> <silent> <F3> <ESC>:IDENext<CR>

  nmap <buffer> <silent> <F4> :<C-U>IDEToCursor<CR>
  imap <buffer> <silent> <F4> <ESC>:IDEToCursor<CR>

  nmap <buffer> <silent> <F5> :<C-U>IDEUndoAll<CR>
  imap <buffer> <silent> <F5> <ESC>:IDEUndoAll<CR>

  nmap <buffer> <silent> <F6> :<C-U>IDEToEOF<CR>
  imap <buffer> <silent> <F6> <ESC>:IDEToEOF<CR>

  nmap <silent> <F7> :<C-U>IDERefresh<CR>
  imap <silent> <F7> <ESC>:IDERefresh<CR>

  nmap <buffer> <silent> <F8> :<C-U>IDEKill<CR>
  imap <buffer> <silent> <F8> <ESC>:IDEKill<CR>

  nnoremap <buffer> <Leader>c :call SetOption(1, 1)<CR>
  nnoremap <buffer> <Leader>C :call SetOption(1, 0)<CR>

  nnoremap <buffer> <Leader>m :call SetOption(2, 1)<CR>
  nnoremap <buffer> <Leader>M :call SetOption(2, 0)<CR>

  nnoremap <buffer> <Leader>n :call SetOption(3, 1)<CR>
  nnoremap <buffer> <Leader>N :call SetOption(3, 0)<CR>

  nnoremap <buffer> <Leader>a :call SetOption(4, 1)<CR>
  nnoremap <buffer> <Leader>A :call SetOption(4, 0)<CR>

  nnoremap <buffer> <Leader>e :call SetOption(5, 1)<CR>
  nnoremap <buffer> <Leader>E :call SetOption(5, 0)<CR>

  nnoremap <buffer> <Leader>u :call SetOption(6, 1)<CR>
  nnoremap <buffer> <Leader>U :call SetOption(6, 0)<CR>

endfunction

" Add a menu item :

amenu <silent> IDE.Next         :IDENext<CR>
amenu <silent> IDE.Previous     :IDEUndo<CR>
amenu <silent> IDE.ToCursor     :IDEToCursor<CR>
amenu <silent> IDE.UndoAll      :IDEUndoAll<CR>
amenu <silent> IDE.EOF          :IDEToEOF<CR>
amenu <silent> IDE.ShowGoalInfo :IDERefresh<CR>
amenu <silent> IDE.Kill         :IDEKill<CR>
"amenu <silent> IDE.Break    :IDEBreak<CR>
" }}}
"
" autocmd  {{{

" This function is called when either the cursor moved or the current buffer
" were modified. In the last case, when need to undo commands after the cursor
" position. AFAIK, VIM does not permit to known the portion of text modified.
" Hence we should use heuristics. The current algorithm is known to be
" incorrect when the user use 'gq' or 'gw' command. However, it is improbable
" the user applies these commands on coq code. When we use to command 'o', the
" script uselessly rewind one command. There must be other commands which fool
" the heuristics.
" Using [nmap] for capturing the last operator seems to be a bad idea.
function ActionOccured(insertmode)
  let [_, l:line, l:col, _] = getpos('.')

  if b:mychangedtick != b:changedtick
    let b:mychangedtick = b:changedtick
    call s:UnsetColorError()
    if ! exists('b:coqtop_pid')
      return
    endif

    let l:llinelen = strlen(getline(b:lastline))
    if b:lastmode && a:insertmode && l:llinelen < b:lastcol - 1
      " in insert mode and tw option + change provoked a cut
      let l:mline = b:lastline
      let l:mcol = l:llinelen
    elseif !b:lastmode && a:insertmode " o O c
      let l:mline = l:line
      let l:mcol = l:col
    else  " correct when the user type 'r<CR>'
      let [l:mline, l:mcol] = s:GetLowest(b:lastline, b:lastcol, l:line, l:col)
    endif

    " A list of commands modifying the text : o O c r s a C S x X d D p P J u U
    if s:UndoToPos(l:mline, l:mcol) != 1
      call s:ShowGoalsInfo()
    endif
  endif

  let b:lastline = l:line
  let b:lastcol = l:col
  let b:lastmode = a:insertmode
endfunction

autocmd CursorMovedI *.v call ActionOccured(1)
autocmd CursorMoved *.v call ActionOccured(0)
autocmd BufWritePost *.v let b:mychangedtick = b:changedtick

function LeaveBuffer()
  if exists('s:in_script')
    let s:lastbuffer = bufnr('%')
  endif
endfunction

" Restore color and save information for [ActionOccured]
function EnterBuffer()
  " First time, we need to initialized some variables :
  if !exists('b:init')
    call s:Debug('Enterbuffer', '>>> Enterbuffer(init)')
    " State used when a cursor moved :
    let b:mychangedtick = b:changedtick " Last value of b:changedtick variable
    let [_, l:line, l:col, _] = getpos('.')
    let b:lastline = l:line
    let b:lastcol = l:col
    let b:lastmode = 0    " normal mode

    " State for ide :
    let b:info = []
    let [b:curline, b:curcol] = [0, 0]
    let [b:tline, b:tcol] = [0, 0]

    let s:lastbuffer = bufnr('%')
    let b:init = 1
    call s:SetNewCommand()
    call s:SetMapKey()
    lcd %:p:h
    call s:Debug('Enterbuffer', '<<< Enterbuffer()')
  endif

  if !exists('s:in_script') && exists('b:coqtop_pid') && s:lastbuffer != bufnr('%')
      call s:Debug('Enterbuffer', '>>> Enterbuffer()')
      call s:ShowGoalsInfo()
      call s:Debug('Enterbuffer', '<<< Enterbuffer()')
  endif

  if !exists('w:curbuf') || w:curbuf != bufnr('%')
    let w:curbuf = bufnr('%')
     call s:SetColorSent()
  endif

endfunction

function EnterWindow()
  if exists('s:tabchanged')
"    echomsg 'Buffer :' . bufnr('%')
    unlet s:tabchanged
    call UpdateColor()
  endif
endfunction

"autocmd BufWipeout *.v call KillCoqtop(1)

autocmd BufLeave *.v call LeaveBuffer()
"autocmd TabEnter *.v echomsg 'Buffer :' . bufnr('%') | let s:tabchanged = 1
autocmd BufEnter *.v call EnterBuffer()
autocmd WinEnter *.v call EnterWindow()

" }}}

