# Overshoot JS SDK Reverse Engineering

## Scope

This note studies the public client-side behavior of `NTD-LAB/overshoot-js-sdk` only.

- Baseline repo: `https://github.com/NTD-LAB/overshoot-js-sdk`
- Baseline commit: `419bfa51eb01721d1fea079450a5c7559b8eefee`
- Package version at that commit: `2.0.0-alpha.7`
- Default API URL: `https://api.overshoot.ai/v0.2`
- Package metadata at this commit still points `repository.url` to `Overshoot-ai/overshoot-js-sdk`, so `NTD-LAB` should be treated as a fork or mirror for research purposes ([package.json#L49-L58](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/package.json#L49-L58))
- Method: read public README, package metadata, TypeScript source, and tests without cloning the repo or touching `OpenHalo` app code

This note answers four questions:

1. How does the SDK really capture screen content?
2. What is the actual processing cadence and default behavior?
3. What transport and lifecycle protocol does the client use?
4. What can and cannot be monitored from outside the closed backend?

## Sources Studied

- [README.md](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/README.md)
- [package.json](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/package.json)
- [src/client/RealtimeVision.ts](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts)
- [src/client/RealtimeVision.test.ts](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.test.ts)
- [src/client/client.ts](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/client.ts)
- [src/client/types.ts](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/types.ts)
- [src/client/livekitTransport.ts](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/livekitTransport.ts)
- [src/client/constants.ts](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/constants.ts)

## Executive Summary

### Official Public Contract

- The SDK exposes `camera`, `video`, `screen`, and `livekit` sources in the README, with `hls` present in source code but not documented in the README.
- The public API is centered on `RealtimeVision`, `StreamClient`, `/streams`, keepalive, prompt updates, stream close, and a result WebSocket.
- The README presents Overshoot as a live video analysis SDK with `clip` and `frame` modes and tunable cadence parameters such as `target_fps`, `clip_length_seconds`, `delay_seconds`, and `interval_seconds`.

### Implementation Inference From This Commit

- `screen` is not implemented as repeated still-image uploads. The current path is `getDisplayMedia` -> raw screen track -> hidden `<video>` -> `<canvas>` redraw loop -> `canvas.captureStream(15)` -> LiveKit publish.
- For non-`livekit` sources, the client first captures media locally, then asks the server to create a stream, then publishes the local video track to a server-created LiveKit room, and finally receives inference results over WebSocket.
- The current code and tests disagree on default mode behavior. README and tests imply default `clip`; `RealtimeVision.ts` currently resolves to default `frame` unless clip settings are present.
- The closed backend remains opaque for frame selection, batching, scheduling, and queueing. Those details are not present in this repo.

## Interface Truths

### Public Contract

- `StreamSource` currently includes `camera`, `video`, `livekit`, `screen`, and `hls` in `types.ts` ([types.ts#L1-L6](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/types.ts#L1-L6)).
- `ClipProcessingConfig` accepts either the preferred `target_fps` form or the deprecated `fps + sampling_ratio` form ([types.ts#L25-L41](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/types.ts#L25-L41)).
- `FrameProcessingConfig` is `interval_seconds` only ([types.ts#L43-L48](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/types.ts#L43-L48)).
- `max_output_tokens` is constrained by an effective rate limit of `128 tokens/sec` according to both README and `types.ts` ([README.md#L148-L183](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/README.md#L148-L183), [types.ts#L65-L76](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/types.ts#L65-L76)).
- The package is MIT-licensed and depends on `livekit-client` and `hls.js` ([package.json#L49-L76](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/package.json#L49-L76)).

### Implementation Inference

- `iceServers` is still declared in the config surface, but no active use of `iceServers` appears in the current `RealtimeVision.ts` control flow ([RealtimeVision.ts#L241-L245](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L241-L245)).
- `peerConnection` is still defined, and `response.webrtc` is still conditionally consumed, but this commit shows no `new RTCPeerConnection`, no offer creation, and no track attachment path. That suggests the direct WebRTC path is vestigial or disabled in the current client file ([RealtimeVision.ts#L275-L276](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L275-L276), [RealtimeVision.ts#L950-L953](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L950-L953)).

## Screen Capture Pipeline

### Official Public Contract

- README says `screen` uses browser `getDisplayMedia`, and the user is prompted to share a screen or window ([README.md#L55-L71](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/README.md#L55-L71)).
- The SDK exposes `getMediaStream()` for local preview and returns `null` only for user-managed `livekit` sources ([README.md#L73-L95](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/README.md#L73-L95), [RealtimeVision.ts#L1196-L1201](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L1196-L1201)).

### Implementation Inference

- `screen` source validation checks for `navigator.mediaDevices.getDisplayMedia` at construction time ([RealtimeVision.ts#L388-L394](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L388-L394)).
- The runtime asks for screen share with `audio: false` and an ideal `1280x720` capture size ([RealtimeVision.ts#L613-L619](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L613-L619)).
- The raw screen track is not published directly. It is first attached to a hidden `<video>` element, then redrawn onto a canvas whose dimensions are capped to `min(raw settings, 1280x720)` ([RealtimeVision.ts#L639-L652](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L639-L652)).
- The SDK redraws the screen canvas at a fixed interval using `DEFAULTS.SCREEN_CAPTURE_FPS`, which is `15` in this commit, then publishes `canvas.captureStream(15)` as the steady stream ([RealtimeVision.ts#L24-L39](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L24-L39), [RealtimeVision.ts#L658-L669](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L658-L669)).
- The reason given in code is important: `getDisplayMedia` may drop frame rate on static screens, so the canvas intermediary is used to guarantee a steady output cadence ([RealtimeVision.ts#L636-L639](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L636-L639)).
- The SDK also stores the raw screen stream separately for cleanup, but the public `getMediaStream()` returns the steady canvas stream, not the raw desktop stream ([RealtimeVision.ts#L675-L682](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L675-L682), [RealtimeVision.ts#L1196-L1201](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L1196-L1201)).

## Processing Modes, Cadence, and Defaults

### Official Public Contract

- README documents `clip` and `frame` modes and presents `clip` as the default mode ([README.md#L217-L255](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/README.md#L217-L255)).
- README documents default clip settings of `target_fps: 6`, `clip_length_seconds: 0.5`, `delay_seconds: 0.5`, and documents default frame interval as `0.2s` ([README.md#L119-L132](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/README.md#L119-L132)).
- Source validation enforces:
  - `target_fps` in `[1, 30]`
  - `fps` in `[1, 120]`
  - `sampling_ratio` in `[0, 1]`
  - `clip_length_seconds` in `[0.1, 60]`
  - `delay_seconds` in `[0, 60]`
  - `interval_seconds` in `[0.1, 60]`
  - `target_fps * clip_length_seconds >= 3`
  ([RealtimeVision.ts#L67-L77](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L67-L77), [RealtimeVision.ts#L408-L505](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L408-L505)).

### Implementation Inference

- Current source defaults are:
  - `TARGET_FPS = 6`
  - `CLIP_LENGTH_SECONDS = 0.5`
  - `DELAY_SECONDS = 0.5`
  - `INTERVAL_SECONDS = 0.5`
  - `SCREEN_CAPTURE_FPS = 15`
  ([RealtimeVision.ts#L24-L39](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L24-L39)).
- `getMode()` returns:
  - explicit `config.mode` if provided
  - otherwise `clip` only if `clipProcessing` or deprecated `processing` has fields
  - otherwise `frame`
  ([RealtimeVision.ts#L795-L817](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L795-L817)).
- `getProcessingConfig()` confirms the runtime behavior:
  - default `frame` => `{ interval_seconds: 0.5 }`
  - default `clip` => `{ target_fps: 6, clip_length_seconds: 0.5, delay_seconds: 0.5 }`
  ([RealtimeVision.ts#L822-L857](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L822-L857)).

## Transport and Lifecycle Protocol

### Official Public Contract

`StreamClient` exposes these public endpoints:

| Endpoint | Method | Role |
| --- | --- | --- |
| `/streams` | `POST` | Create a stream and receive stream metadata |
| `/streams/:id/keepalive` | `POST` | Renew lease / keep stream alive |
| `/streams/:id/config/prompt` | `PATCH` | Update prompt during an active stream |
| `/streams/:id` | `DELETE` | Explicitly stop and clean up a stream |
| `/models` | `GET` | Query model readiness |
| `/ws/streams/:id` | `WebSocket` | Receive inference results |

Evidence: [client.ts#L110-L176](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/client.ts#L110-L176).

The typed protocol surfaces:

- `StreamCreateRequest` with `source`, `mode`, `processing`, `inference`, and optional `client` metadata
- `StreamCreateResponse` with `stream_id`, optional `webrtc`, optional `livekit`, optional `lease`, and optional `turn_servers`
- `StreamInferenceResult` with `result`, `inference_latency_ms`, `total_latency_ms`, `finish_reason`, and stream/model metadata
- `KeepaliveResponse` with optional `livekit_token`
- `StreamStopReason` values such as `client_requested`, `webrtc_disconnected`, `livekit_disconnected`, `lease_expired`, and `insufficient_credits`

Evidence: [types.ts#L93-L178](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/types.ts#L93-L178).

### Implementation Inference

The active control flow in this commit is:

1. Validate config and source support.
2. Capture or prepare local media unless `source.type === "livekit"`.
3. Resolve mode and processing config.
4. `POST /streams`.
5. If `response.livekit` and local media exist, connect to the returned LiveKit room and publish the local video track.
6. Store `stream_id`.
7. Start keepalive at `ttl_seconds / 2`.
8. Connect WebSocket and send `{"api_key": ...}` on open.
9. Parse each WebSocket message into `StreamInferenceResult` and invoke `onResult`.
10. On stop or fatal error, disconnect local LiveKit first, then `DELETE /streams`, then stop local tracks and remove canvas/video resources.

Evidence: [RealtimeVision.ts#L871-L985](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L871-L985), [RealtimeVision.ts#L995-L1307](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L995-L1307), [livekitTransport.ts#L11-L55](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/livekitTransport.ts#L11-L55).

Important transport observations:

- For non-`livekit` sources, local video is not uploaded through repeated HTTP frame posts. It is published as a media track into a LiveKit room returned by the server ([RealtimeVision.ts#L925-L974](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L925-L974), [livekitTransport.ts#L40-L45](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/livekitTransport.ts#L40-L45)).
- The published LiveKit track is tagged as `Track.Source.Camera` even when the underlying source is screen capture, which matters if downstream analytics or debugging tools rely on the source tag ([livekitTransport.ts#L42-L45](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/livekitTransport.ts#L42-L45)).
- WebSocket is used for inference results, not for raw media upload ([client.ts#L150-L155](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/client.ts#L150-L155), [RealtimeVision.ts#L1025-L1047](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L1025-L1047)).
- Keepalive can return `livekit_token`, and the client passes it into `livekitTransport.updateToken()` ([RealtimeVision.ts#L1005-L1010](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L1005-L1010)).
- In this commit, `updateToken()` only updates a local variable and does not call a visible LiveKit SDK refresh method. That means token refresh behavior is not fully transparent from this client code alone ([livekitTransport.ts#L21-L24](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/livekitTransport.ts#L21-L24), [livekitTransport.ts#L47-L54](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/livekitTransport.ts#L47-L54)).
- WebSocket close handling distinguishes:
  - `1008` for auth failure
  - `1001` with reason for server-initiated stream end
  - other closes trigger exponential reconnect up to five attempts
  ([RealtimeVision.ts#L1054-L1114](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L1054-L1114)).

## Docs vs Tests vs Source Differences

| Topic | README | Tests | Source | Judgment |
| --- | --- | --- | --- | --- |
| Default mode when `mode` is omitted | Says default is `clip` ([README.md#L221-L255](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/README.md#L221-L255)) | Expects default processing payload to be clip-style `target_fps` ([RealtimeVision.test.ts#L282-L292](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.test.ts#L282-L292)) | `getMode()` returns `frame` unless clip config is present ([RealtimeVision.ts#L801-L817](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L801-L817)) | Current source and tests are inconsistent. Runtime truth in this commit is the source implementation. |
| Default frame interval | Says `0.2s` ([README.md#L129-L132](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/README.md#L129-L132), [README.md#L243-L249](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/README.md#L243-L249)) | No explicit default frame interval assertion | `DEFAULTS.INTERVAL_SECONDS = 0.5` ([RealtimeVision.ts#L33-L36](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L33-L36)) | README is stale relative to source. |
| `hls` source | Not documented in `StreamSource` section ([README.md#L138-L146](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/README.md#L138-L146)) | No visible HLS tests in the studied test file | `hls` is accepted in config, source validation, and media creation ([types.ts#L1-L6](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/types.ts#L1-L6), [RealtimeVision.ts#L173-L180](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L173-L180), [RealtimeVision.ts#L395-L399](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L395-L399), [RealtimeVision.ts#L695-L703](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L695-L703)) | README under-documents the current source surface. |
| Mode inference model | Types comment says `interval_seconds` implies frame, otherwise clip ([types.ts#L50-L58](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/types.ts#L50-L58)) | Tests assume default clip payload ([RealtimeVision.test.ts#L282-L292](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.test.ts#L282-L292)) | Runtime logic is clip only when clip config is present, else frame ([RealtimeVision.ts#L806-L817](https://github.com/NTD-LAB/overshoot-js-sdk/blob/419bfa51eb01721d1fea079450a5c7559b8eefee/src/client/RealtimeVision.ts#L806-L817)) | Internal comments and runtime logic are not perfectly aligned. |

## What You Can Observe and What Stays Opaque

| Signal | Access Level | How To Observe | What It Actually Proves |
| --- | --- | --- | --- |
| `stream_id` | Public SDK | `vision.getStreamId()` after `start()` | Confirms stream creation succeeded and lets you correlate result logs with one logical stream. |
| Post-canvas local track settings | Public SDK | `vision.getMediaStream()?.getVideoTracks()[0].getSettings()` | Shows the steady stream published by the SDK after canvas normalization, not the raw desktop share track. |
| Result cadence | Public SDK | Timestamp each `onResult` callback | Shows delivered inference cadence from server to client. |
| `inference_latency_ms`, `total_latency_ms`, `finish_reason` | Public SDK | Read fields from each `StreamInferenceResult` | Shows server-reported model latency and end-to-end latency for each result. |
| Prompt mutation events | Public SDK | Call `updatePrompt()` and log before/after | Shows when the active prompt changed for an existing stream. |
| Keepalive interval | Source + runtime logs | Derived from `ttl_seconds / 2`; optionally log renew timestamps | Shows client lease-renew policy, not server scheduler internals. |
| Raw `getDisplayMedia` track settings | SDK fork or browser instrumentation | Expose `rawScreenStream`, or inspect browser internals | Shows the browser-provided raw desktop share before canvas smoothing. |
| Outbound publish fps / sent frames / resolution | Browser WebRTC internals or SDK fork | `chrome://webrtc-internals`, custom LiveKit instrumentation, or forked handle exposure | Shows transport behavior between client and media server. |
| WebSocket close codes and raw reasons | Browser devtools or SDK fork | Network tools or patched SDK | Shows exact closure reason and reconnect behavior. |
| Server-selected frames, batching, queueing, sampling scheduler | Opaque | Not exposed by this repo | Remains a closed backend concern. |

## Runtime Verification Plan

This note does not execute runtime validation, but the next step should be a minimal browser harness that measures the public and inferred behavior separately.

### Phase 1: Public SDK Validation

- Start `RealtimeVision` with `source: { type: "screen" }` and `debug: true`.
- Log `vision.getStreamId()`.
- Read `vision.getMediaStream()?.getVideoTracks()[0].getSettings()` after `start()`.
- Timestamp every `onResult` callback and record:
  - `stream_id`
  - `mode`
  - `model_name`
  - `inference_latency_ms`
  - `total_latency_ms`
  - `finish_reason`
  - delta from previous result

### Phase 2: Browser / Transport Validation

- Open browser network tools and confirm:
  - `POST /streams`
  - `POST /streams/:id/keepalive`
  - `PATCH /streams/:id/config/prompt`
  - `DELETE /streams/:id`
  - `WebSocket /ws/streams/:id`
- Use browser WebRTC internals to inspect outbound media stats and confirm the published stream is steady even when the screen is static.

### Phase 3: If Deeper Validation Is Needed

- Fork or patch the SDK to expose:
  - `rawScreenStream`
  - LiveKit room / sender stats
  - raw WebSocket close code and reason
- Compare raw desktop share track settings against post-canvas `getMediaStream()` settings to quantify the smoothing step.

## Chrome MCP Runtime Probe

The runtime probe was executed in Chrome against a local harness page, using the public SDK from jsDelivr and a real Overshoot API key. The harness page used browser-side instrumentation around `fetch`, `WebSocket`, `getDisplayMedia`, and `RTCPeerConnection`.

Probe artifact:

- Local harness: `/Users/aaronpang/Desktop/OpenHalo/tmp/overshoot_runtime_probe.html`

What was directly verified:

- `screen` capture required the normal browser picker flow, and after permission was granted the raw shared surface resolved as a `window` display surface at `1210x720` and `30fps`.
- The public `vision.getMediaStream()` steady stream resolved at the same `1210x720` dimensions but `15fps`, matching the source-code claim that the SDK smooths screen capture through a fixed-rate canvas stream.
- A real `POST https://api.overshoot.ai/v0.2/streams` request was observed with:
  - `mode: "frame"`
  - `processing.interval_seconds: 0.5`
  - `backend: "overshoot"`
  - `model: "Qwen/Qwen3-VL-8B-Instruct"`
- The stream create response returned:
  - `201 Created`
  - a real `stream_id`
  - `lease.ttl_seconds: 90`
  - `livekit.url`
  - `livekit.token`
  - `webrtc: null`
- A LiveKit WebSocket opened, then the Overshoot result WebSocket opened, matching the inferred transport order from the static source read.
- A `RTCPeerConnection` instance was observed and reached `connectionState: "connected"`.
- Outbound RTP stats showed actual publishing, but at encoder-downscaled resolutions such as `302x180` and later `453x270`, with `qualityLimitationReason: "bandwidth"`. That means the locally steady `1210x720 @ 15fps` stream can still be reduced further by transport or encoder conditions.
- The first observed result arrived in about `1.14s` total latency. Subsequent result intervals were often around `0.17s` to `0.63s`, not a perfectly rigid `0.5s`, and some returned `total_latency_ms` around `5.1s` while other nearby results were much faster. This strongly suggests backend concurrency or queueing behavior that is not exposed in the client repo.
- Stopping the stream closed the LiveKit socket cleanly (`1000`) and the Overshoot result socket cleanly (`1005` with no reason surfaced in the page log). The subsequent `DELETE /streams/:id` returned `404 stream_not_found`, which implies the stream had already been torn down server-side before the explicit client delete completed.

What this runtime probe changes relative to the static analysis:

- The `getDisplayMedia -> canvas.captureStream(15)` claim is now runtime-confirmed, not just source-inferred.
- The `POST /streams -> LiveKit connect -> result WebSocket` sequence is runtime-confirmed.
- The `frame interval = 0.5` setting was actually sent over the wire in this run.
- Result cadence is not simply equal to the configured interval. The interval acts more like a target scheduling rate than a strict delivery guarantee.
- Encoder or network conditions can reduce outbound frame size below the locally steady stream dimensions even with the current client defaults.

## Monitoring Checklist

Use this exact field list in any future measurement run:

- `timestamp`
- `stream_id`
- `source_type`
- `mode`
- `processing_config`
- `model_name`
- `api_url`
- `steady_track_width`
- `steady_track_height`
- `steady_track_frame_rate`
- `raw_track_width` if instrumented
- `raw_track_height` if instrumented
- `raw_track_frame_rate` if instrumented
- `result_id`
- `result_interval_ms`
- `inference_latency_ms`
- `total_latency_ms`
- `finish_reason`
- `result_ok`
- `result_error`
- `keepalive_sent_at`
- `keepalive_ttl_seconds`
- `keepalive_returned_livekit_token`
- `ws_opened_at`
- `ws_closed_at`
- `ws_close_code`
- `ws_close_reason`
- `livekit_reconnecting_at`
- `livekit_reconnected_at`
- `livekit_disconnected_reason`

## Black Box Boundary

The following conclusions are supported by the public client repo:

- Screen input is smoothed into a steady 15 fps canvas stream before publishing.
- Media transport is LiveKit-centered for the active non-user-managed path in this commit.
- Result delivery is WebSocket-based.
- The client-side cadence knobs are public and well-defined.

The following remain unverified because they are server-side concerns not implemented in this repo:

- Which exact frames the server samples for `clip` or `frame` mode
- Whether the backend performs additional downsampling, deduplication, or batch scheduling
- How the backend prioritizes streams under load
- Whether `livekit_token` renewal is consumed by server-side reconnection logic even though the client-side room refresh path is not visible here

## Practical Bottom Line

If the goal is to reproduce Overshoot's public client behavior, the key model is:

`browser capture -> steady video track -> LiveKit publish -> WebSocket results`

If the goal is to monitor it, split measurement into three layers:

- local steady stream properties
- transport stats
- result cadence and latencies

If the goal is to go beyond this and reproduce the backend scheduler, this repo is not enough. That part is still a closed system.
