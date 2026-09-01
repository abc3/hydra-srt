# YouTube sources

HydraSRT can resolve a YouTube watch URL with yt-dlp and ingest the resulting HLS
playlist. The stream then uses the normal HydraSRT MPEG-TS route path and can fan out
to SRT, UDP, RTMP, or NDI outputs.

YouTube support is on by default and can be turned off with `YOUTUBE_ENABLED=false`. Configure a source
with schema `YOUTUBE` through the API or route editor, then enter a YouTube watch URL,
an optional quality selection, and an optional end action. Version 1 supports the
`stop` end action.

The inspect API is `GET /api/youtube/formats?url=<watch-url>`. It returns available
variants without returning the resolved media URL. To request a fresh resolution, use
`POST /api/youtube/refresh` with a JSON body containing `url` and, optionally,
`format_id` or `quality_policy`.

## Access and yt-dlp maintenance

Resolution succeeding is not evidence that playback will work. A stale yt-dlp can
successfully resolve a source while producing a playlist that the media server rejects;
the route then appears to have resolved but does not play. Keeping yt-dlp current is an
operational requirement.

The container ships the current stable yt-dlp release as a checksum-verified pinned
binary. The Docker build checks the downloaded version, Python runtime, and CA bundle;
there is no first-run download or interactive setup. The standalone binary includes its
Python runtime, and the image also installs system Python and `ca-certificates` so TLS
prerequisites are present and visible during the build.

The image disables yt-dlp's cache in `/etc/yt-dlp.conf`, so resolution does not depend on
a writable home directory. Update `YT_DLP_VERSION` and both architecture checksums in the
Dockerfile as part of image maintenance when YouTube extraction changes. The explicit pin
prevents silent drift, while a checksum or download failure makes an outdated pin a build
failure instead of a runtime surprise. Operators may set `YT_DLP_PATH` to a newer
operator-managed executable without waiting for a HydraSRT release; it must accept the
yt-dlp command line used by HydraSRT.

The resolver pins the `mweb` player client, with `android` as a fallback. This is
load-bearing: as of August 19, 2026, those clients provide a muxed audio/video HLS
rendition, while the default client path can return separate audio-only and video-only
renditions. That setting may need maintenance as YouTube changes its clients.

If YouTube presents a bot check, resolution fails with a bot-check error. A cookies file
can be supplied with `YOUTUBE_COOKIES_PATH`; mount the file into the HydraSRT container
and set the variable to its path. Cookies bind resolution to the account that supplied
them. The operator is responsible for protecting that account, rotating the file, and
accepting the account and platform-policy risks. Some YouTube deployments may also
require PO tokens; HydraSRT does not configure them in v1.

Age-gated and members-only content is not supported in v1.

## Latency and lifecycle

Live HLS starts near the live edge, approximately three five-second segments behind it.
Expected end-to-end latency is roughly 15 to 20 seconds. This live-edge offset is fixed
in v1 and is not configurable.

The resolved playlist URL expires after roughly six hours. HydraSRT refreshes it under
its controlled refresh cycle, terminates the old native process, and starts a new one.
The route reports `reconnecting` during this transition. Outputs may drop during a
refresh or reconnect; downstream receivers must reconnect. This is expected behavior,
and HydraSRT does not promise output continuity across a source restart.

Live sources retry after source loss or a failed refresh. A VOD source ends normally
when its playlist reaches the end and the route enters the `completed` state when
`end_action=stop`; it is not retried as a failure.

## Rights and terms

YouTube and content owners may impose terms, access controls, or other restrictions on
retrieval and redistribution. Restreaming content that you do not own or have not
cleared is the operator's responsibility. YouTube is a trademark of Google LLC.
