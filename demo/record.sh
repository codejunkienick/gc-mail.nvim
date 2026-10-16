#!/bin/sh
# Records a presentation video of the plugin's windows, headless.
#
#   demo/record.sh [--out FILE.mp4] [--tour FILE] [--size WxH] [--gif FILE] [--webp FILE]
#
# A fresh Xvfb display runs a terminal (alacritty, else wezterm) with Neovim
# and the plugin against a fake demo city (demo/bin/gc); the tour is typed at
# human speed while demo/keys.lua shows each key and the captions, an agent
# reply arrives live, and ffmpeg grabs the display into an MP4. A second
# ffmpeg pass writes a 960 px wide 12 fps palette GIF (--gif) or a 1280 px
# wide 15 fps animated WebP (--webp) from that MP4. Nothing touches the real
# screen, the real gc
# or any real city: everything lives in one temporary directory that is
# removed on exit.
#
# Tour file, one step per line:
#   key <xdotool key names>   one chord or a sequence: key space m p
#   type <text>               ASCII, about 12 characters a second
#   wait <ms>
#   say <caption>             a caption through the Neovim socket (never a key)
#   agent <args...>           demo/bin/gc as an agent: agent mayor reply latest <text>
#   # comment                 blank lines are skipped
#
# Exit codes: 0 a non-empty MP4 was written; 1 the run failed; 2 usage, a
# missing tool, a bad tour (the line is named) or a refused safety check.
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
out=./gc-mail-demo.mp4
tour="$here/tour-basic.txt"
size=1920x1080
gif=
webp=

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'record.sh: %s\n' "$*" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case $1 in
    --out) [ $# -ge 2 ] || die '--out needs a file'; out=$2; shift 2 ;;
    --tour) [ $# -ge 2 ] || die '--tour needs a file'; tour=$2; shift 2 ;;
    --size) [ $# -ge 2 ] || die '--size needs WxH'; size=$2; shift 2 ;;
    --gif) [ $# -ge 2 ] || die '--gif needs a file'; gif=$2; shift 2 ;;
    --webp) [ $# -ge 2 ] || die '--webp needs a file'; webp=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

case $size in
  [0-9]*x[0-9]*) ;;
  *) die "--size must be WxH, got: $size" ;;
esac
width=${size%x*}
height=${size#*x}
case $width$height in
  *[!0-9]*) die "--size must be WxH, got: $size" ;;
esac
[ $((width % 2)) -eq 0 ] && [ $((height % 2)) -eq 0 ] || die "--size must have even sides (yuv420p), got: $size"
[ -f "$tour" ] && [ -r "$tour" ] || die "cannot read the tour: $tour"

# ---- the tour is checked before anything starts ------------------------------

blank_or_comment() {
  case $1 in
    ''|'#'*) return 0 ;;
  esac
  return 1
}

trim() {
  # Leading and trailing whitespace off $1.
  t=${1#"${1%%[![:space:]]*}"}
  printf '%s' "${t%"${t##*[![:space:]]}"}"
}

n=0
while IFS= read -r raw || [ -n "$raw" ]; do
  n=$((n + 1))
  line=$(trim "$raw")
  blank_or_comment "$line" && continue
  step=${line%%[[:space:]]*}
  rest=$(trim "${line#"$step"}")
  case $step in
    key|type|agent) [ -n "$rest" ] || die "tour line $n: '$step' needs an argument" ;;
    say) ;;
    wait)
      case $rest in
        ''|*[!0-9]*) die "tour line $n: 'wait' needs a number of milliseconds" ;;
      esac ;;
    *) die "tour line $n: unknown step '$step'" ;;
  esac
done < "$tour"

# ---- never the real gc, never the real screen --------------------------------

# Every GC_*, BEADS_* and BD_* variable goes: the demo gc takes its state from
# GC_DEMO_DIR, which is set below. GC_DEMO_MARKVIEW survives: demo/init.lua
# reads it for recording-only markdown rendering.
demo_markview=${GC_DEMO_MARKVIEW:-}
for name in $(env | sed -n 's/^\(GC_[A-Za-z0-9_]*\|BEADS_[A-Za-z0-9_]*\|BD_[A-Za-z0-9_]*\)=.*/\1/p'); do
  unset "$name"
done
if [ -n "$demo_markview" ]; then
  case $demo_markview in
    /*) ;;
    *) demo_markview=$PWD/$demo_markview ;;
  esac
  GC_DEMO_MARKVIEW=$demo_markview
  export GC_DEMO_MARKVIEW
fi
# alacritty and wezterm prefer Wayland when it is set: they would open on the
# real desktop.
unset WAYLAND_DISPLAY DISPLAY XAUTHORITY

PATH="$here/bin:$PATH"
export PATH
[ "$(command -v gc || true)" = "$here/bin/gc" ] || die "refusing to start: gc on PATH is not $here/bin/gc"

terminal=
for candidate in alacritty wezterm; do
  if command -v "$candidate" >/dev/null 2>&1; then
    terminal=$candidate
    break
  fi
done
missing=
for tool in Xvfb xdotool ffmpeg nvim timeout mktemp; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
[ -n "$terminal" ] || missing="$missing alacritty(or wezterm)"
[ -z "$missing" ] || die "missing tools:$missing"

case $out in
  /*) ;;
  *) out=$PWD/$out ;;
esac
mkdir -p "$(dirname "$out")"
if [ -n "$gif" ]; then
  case $gif in
    /*) ;;
    *) gif=$PWD/$gif ;;
  esac
  mkdir -p "$(dirname "$gif")"
fi
if [ -n "$webp" ]; then
  case $webp in
    /*) ;;
    *) webp=$PWD/$webp ;;
  esac
  mkdir -p "$(dirname "$webp")"
fi

# ---- one temporary directory holds everything ---------------------------------

# The cleanup comes first and the traps are set on the line after mktemp -d, so
# the directory never survives an early exit of `set -e`.
tmp=
xvfb_pid= term_pid= nvim_pid= ffmpeg_pid= ffmpeg_status=0

alive() {
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null
}

# Waits up to $2 tenths of a second for pid $1 to end.
wait_gone() {
  i=0
  while alive "$1" && [ "$i" -lt "$2" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  ! alive "$1"
}

stop_ffmpeg() {
  [ -n "$ffmpeg_pid" ] || return 0
  if alive "$ffmpeg_pid"; then
    # q on ffmpeg's stdin finalizes the file.
    printf q >&4 2>/dev/null || true
    wait_gone "$ffmpeg_pid" 150 || kill "$ffmpeg_pid" 2>/dev/null || true
  fi
  wait "$ffmpeg_pid" 2>/dev/null || ffmpeg_status=$?
  ffmpeg_pid=
}

stop_process() {
  alive "$1" || return 0
  kill "$1" 2>/dev/null || true
  wait_gone "$1" 30 || kill -KILL "$1" 2>/dev/null || true
}

cleanup() {
  status=$?
  trap '' INT TERM
  stop_ffmpeg
  stop_process "$nvim_pid"
  stop_process "$term_pid"
  stop_process "$xvfb_pid"
  # The children are ours: reap them, no one left behind.
  wait 2>/dev/null || true
  exec 4>&-
  [ -z "$tmp" ] || rm -rf "$tmp"
  exit "$status"
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/gc-mail-demo.XXXXXX")
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
sock=$tmp/nvim.sock
mkdir -p "$tmp/home" "$tmp/config" "$tmp/cache" "$tmp/state" "$tmp/data" "$tmp/run" "$tmp/tmp"
chmod 700 "$tmp/run"
HOME=$tmp/home
XDG_CONFIG_HOME=$tmp/config
XDG_CACHE_HOME=$tmp/cache
XDG_STATE_HOME=$tmp/state
XDG_DATA_HOME=$tmp/data
XDG_RUNTIME_DIR=$tmp/run
TMPDIR=$tmp/tmp
GC_DEMO_DIR=$tmp/demo
# A send takes a moment, as with a real gc: the chat's sending… block can be seen.
GC_DEMO_SEND_DELAY_MS=2500
NVIM_LOG_FILE=$tmp/nvim.log
export HOME XDG_CONFIG_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_RUNTIME_DIR TMPDIR GC_DEMO_DIR GC_DEMO_SEND_DELAY_MS NVIM_LOG_FILE
mkdir -p "$GC_DEMO_DIR"

fail() {
  printf 'record.sh: %s\n' "$*" >&2
  exit 1
}

gc seed >/dev/null || fail 'cannot seed the demo store'

# ---- the display --------------------------------------------------------------

Xvfb -displayfd 3 -screen 0 "${width}x${height}x24" -nolisten tcp +extension GLX +render -noreset \
  3>"$tmp/display" >"$tmp/xvfb.log" 2>&1 &
xvfb_pid=$!
i=0
number=
while [ "$i" -lt 100 ]; do
  alive "$xvfb_pid" || fail "Xvfb did not start: $(tail -n 3 "$tmp/xvfb.log")"
  number=$(cat "$tmp/display" 2>/dev/null || true)
  [ -n "$number" ] && break
  sleep 0.1
  i=$((i + 1))
done
case $number in
  ''|*[!0-9]*) fail 'Xvfb did not report a display number' ;;
esac
DISPLAY=:$number
export DISPLAY

# Every xdotool call names this display and the demo window.
xdo() {
  DISPLAY=:$number timeout 30 xdotool "$@"
}

# ---- the terminal with Neovim -------------------------------------------------

class=gc-mail-demo
cat > "$tmp/alacritty.toml" <<'EOF'
[general]
ipc_socket = false

[font]
size = 22

[window]
decorations = "None"

[window.padding]
x = 12
y = 8
EOF
cat > "$tmp/wezterm.lua" <<'EOF'
return {
  font_size = 22.0,
  enable_tab_bar = false,
  window_decorations = "NONE",
  enable_wayland = false,
  check_for_updates = false,
}
EOF

inner='echo $$ > "$1"; shift; exec "$@"'
if [ "$terminal" = alacritty ]; then
  alacritty --config-file "$tmp/alacritty.toml" --class "$class" \
    -e sh -c "$inner" sh "$tmp/nvim.pid" nvim --clean -u "$here/init.lua" --listen "$sock" \
    >"$tmp/terminal.log" 2>&1 &
else
  wezterm --config-file "$tmp/wezterm.lua" start --always-new-process --class "$class" -- \
    sh -c "$inner" sh "$tmp/nvim.pid" nvim --clean -u "$here/init.lua" --listen "$sock" \
    >"$tmp/terminal.log" 2>&1 &
fi
term_pid=$!

wid=$(xdo search --sync --onlyvisible --class "$class" 2>/dev/null | head -n 1) || true
case $wid in
  ''|*[!0-9]*) fail "the $terminal window did not appear: $(tail -n 3 "$tmp/terminal.log")" ;;
esac
xdo windowmove "$wid" 0 0 windowsize "$wid" "$width" "$height" windowfocus "$wid"

i=0
while [ "$i" -lt 150 ]; do
  alive "$term_pid" || fail "$terminal ended early: $(tail -n 3 "$tmp/terminal.log")"
  [ -S "$sock" ] && break
  sleep 0.1
  i=$((i + 1))
done
[ -S "$sock" ] || fail 'Neovim did not open its socket'
nvim_pid=$(cat "$tmp/nvim.pid" 2>/dev/null || true)

remote() {
  timeout 10 nvim --clean -n --server "$sock" --remote-expr "$1" >/dev/null
}
i=0
until remote 'v:true' 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 100 ] || fail 'Neovim does not answer on its socket'
  sleep 0.1
done
sleep 1.5

# ---- the recording ------------------------------------------------------------

mkfifo "$tmp/ffmpeg.in"
exec 4<>"$tmp/ffmpeg.in"
ffmpeg -y -loglevel error -f x11grab -draw_mouse 0 -framerate 30 -video_size "$size" -i ":$number.0" \
  -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p "$tmp/out.mp4" \
  0<&4 >"$tmp/ffmpeg.log" 2>&1 &
ffmpeg_pid=$!
sleep 1.5
alive "$ffmpeg_pid" || fail "ffmpeg did not start: $(tail -n 3 "$tmp/ffmpeg.log")"

pause() {
  # Milliseconds to seconds, no floating point.
  sleep "$(printf '%d.%03d' $(($1 / 1000)) $(($1 % 1000)))"
}

step_key() {
  # shellcheck disable=SC2086
  set -- $1
  xdo windowfocus "$wid"
  xdo key --window "$wid" --delay 140 -- "$@"
  pause 350
}

step_type() {
  text=$1
  xdo windowfocus "$wid"
  while [ -n "$text" ]; do
    char=${text%"${text#?}"}
    text=${text#?}
    xdo type --window "$wid" --delay 0 -- "$char"
    # About 12 characters a second, with a little jitter.
    jitter=$(od -An -N1 -tu1 /dev/urandom | tr -d ' ')
    pause $((60 + jitter % 50))
  done
  pause 250
}

step_say() {
  quoted=$(printf '%s' "$1" | sed "s/'/''/g")
  remote "v:lua.require'demo.keys'.say('$quoted')"
}

step_agent() {
  # shellcheck disable=SC2086
  set -f
  set -- $1
  set +f
  gc agent "$@" >/dev/null </dev/null
}

n=0
while IFS= read -r raw <&5 || [ -n "$raw" ]; do
  n=$((n + 1))
  line=$(trim "$raw")
  blank_or_comment "$line" && continue
  alive "$term_pid" || fail "$terminal ended during tour line $n"
  step=${line%%[[:space:]]*}
  rest=$(trim "${line#"$step"}")
  case $step in
    key) step_key "$rest" ;;
    type) step_type "$rest" ;;
    wait) pause "$rest" ;;
    say) step_say "$rest" ;;
    agent) step_agent "$rest" ;;
    *) fail "tour line $n: unknown step '$step'" ;;
  esac
done 5< "$tour"

# ---- finish -------------------------------------------------------------------

pause 1500
stop_ffmpeg
[ "$ffmpeg_status" -eq 0 ] || fail "ffmpeg did not finish cleanly (exit $ffmpeg_status): $(tail -n 3 "$tmp/ffmpeg.log")"
[ -s "$tmp/out.mp4" ] || fail 'ffmpeg wrote an empty file'
mv -f "$tmp/out.mp4" "$out"
printf 'recorded %s\n' "$out"

# ---- a second ffmpeg pass writes the small sharing files ----------------------
# The GIF is 960 px wide at 12 fps from the recorded MP4 and goes through
# a palette for readable text; the WebP is 1280 px wide at 15 fps.
if [ -n "$gif" ]; then
  ffmpeg -y -loglevel error -i "$out" -vf "fps=12,scale=960:-1:flags=lanczos,palettegen" "$tmp/palette.png" \
    >"$tmp/gif-palette.log" 2>&1 || fail "ffmpeg palette failed: $(tail -n 3 "$tmp/gif-palette.log")"
  ffmpeg -y -loglevel error -i "$out" -i "$tmp/palette.png" \
    -lavfi "fps=12,scale=960:-1:flags=lanczos [x]; [x][1:v] paletteuse" "$gif" \
    >"$tmp/gif.log" 2>&1 || fail "ffmpeg GIF failed: $(tail -n 3 "$tmp/gif.log")"
  [ -s "$gif" ] || fail 'ffmpeg wrote an empty GIF'
  printf 'recorded %s\n' "$gif"
fi
if [ -n "$webp" ]; then
  ffmpeg -y -loglevel error -i "$out" -vf "fps=15,scale=1280:-1:flags=lanczos" \
    -c:v libwebp -lossless 0 -quality 85 -cr_threshold 50 -cr_size 16 -loop 0 "$webp" \
    >"$tmp/webp.log" 2>&1 || fail "ffmpeg WebP failed: $(tail -n 3 "$tmp/webp.log")"
  [ -s "$webp" ] || fail 'ffmpeg wrote an empty WebP'
  printf 'recorded %s\n' "$webp"
fi
exit 0
