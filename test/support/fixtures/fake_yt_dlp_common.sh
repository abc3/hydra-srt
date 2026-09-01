#!/bin/sh
set -eu

url=${YOUTUBE_TEST_URL:-http://127.0.0.1:8080/playlist.m3u8}
format_id=${YOUTUBE_TEST_FORMAT_ID:-96}
expire=${YOUTUBE_TEST_EXPIRE:-}

if [ -n "$expire" ]; then
  case "$url" in
    *\?*) url="${url}&expire=${expire}" ;;
    *) url="${url}?expire=${expire}" ;;
  esac
fi

is_live=${FAKE_YOUTUBE_IS_LIVE:-true}
vbr=${FAKE_YOUTUBE_VBR-948}
abr=${FAKE_YOUTUBE_ABR-130}
tbr=${FAKE_YOUTUBE_TBR-1078}

if [ -z "$vbr" ]; then vbr=null; fi
if [ -z "$abr" ]; then abr=null; fi
if [ -z "$tbr" ]; then tbr=null; fi

case "$is_live" in
  true|True|TRUE) is_live=true ;;
  *) is_live=false ;;
esac

printf '%s\n' "$url"
# Real yt-dlp prints one JSON object for the --print template the resolver uses.
printf '{"id": "%s", "is_live": %s, "format_id": "%s", "title": "%s", "uploader": "%s", "webpage_url": "%s", "vbr": %s, "abr": %s, "tbr": %s}\n' \
  "${FAKE_YOUTUBE_ID:-fixture}" "$is_live" "$format_id" \
  "${FAKE_YOUTUBE_TITLE:-Hydra HLS fixture}" \
  "${FAKE_YOUTUBE_UPLOADER:-HydraSRT}" \
  "${FAKE_YOUTUBE_WEBPAGE_URL:-https://www.youtube.com/watch?v=fixture}" \
  "$vbr" "$abr" "$tbr"
