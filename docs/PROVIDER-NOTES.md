# Provider notes

How `api.scx.ai` behaves, and why the executor maps it to Apple's Foundation Models types the
way it does. This is the reference behind `SCXExecutor` and `SCXClient`. Keep it current: when
the API changes, record the new behaviour here before changing a mapping.

## Base

- Base URL `https://api.scx.ai/v1`, OpenAI Chat Completions compatible.
- `temperature` range is 0–1, where OpenAI allows 0–2. The executor clamps.
- `top_k` is supported, as are `top_p` and `seed`.
- Streaming is Server-Sent Events. The package always streams, including for non-streamed
  `respond(to:)` calls, because Apple's session builds its result from streamed snapshots.

## Errors

| Status | `type` | Meaning | Executor mapping |
|--------|--------|---------|------------------|
| 400 | `invalid_request_error` | bad request; `param` names the field | with attachments and no `param` → `unsupportedTranscriptContent`; `param == "messages"` → `contextSizeExceeded`; else propagates |
| 401 | `authentication_error` | bad key | propagates |
| 402 | `insufficient_credit` | organization out of credit | propagates |
| 403 | `permission_error` | key lacks access to the model | propagates |
| 404 | `not_found_error` | unknown resource or model | propagates |
| 413 | `invalid_request_error` | body too large | with attachments → `unsupportedTranscriptContent`, else `contextSizeExceeded` |
| 429 | `rate_limit_error` / `quota_exceeded` | rate or budget limit hit | `rateLimited` |
| 500 | `api_error` | server error | propagates |
| 503 | | "Upstream provider is temporarily unavailable", seen on MAGPiE | `rateLimited` |
| 529 | `overloaded_error` | model overloaded, transient | `rateLimited` |

The error body is `{"error":{"message","type","param?","code?"}}` and `SCXError` captures all
four fields. Statuses that propagate reach the app as `SCXError` with the API's own message:
`LanguageModelError` has no case for authentication, credit or permission, so passing the real
message through is the intended behaviour rather than a gap.

Network failures: only `URLError.timedOut` maps to `LanguageModelError.timeout`. Offline,
connection lost and DNS failures propagate as `URLError`, because `LanguageModelError` has no
network case. Its full case list is `contextSizeExceeded`, `rateLimited`, `guardrailViolation`,
`refusal`, `unsupportedCapability`, `unsupportedTranscriptContent`, `unsupportedGenerationGuide`,
`unsupportedLanguageOrLocale` and `timeout`.

## Model catalogue

`/v1/models` lists every model on the platform, not only the chat models. Image generation and
editing, video generation, speech, embedding and moderation entries share the same endpoint and
answer `/chat/completions` with 400 `invalid_request_error` "Unsupported model". The `param` is
`"model"`, so the executor's `contextSizeExceeded` guard correctly does not fire.

`SCXLanguageModel.load` rejects those entries before the first prompt, by modality:
`input_modalities` and `output_modalities` must both include `text`, and the moderation
classifier is excluded. The test is on modality rather than `supported_features`, so a future
chat model still loads without a package change.

An entry can carry a `datacenters` list, and its country codes become `ModelInfo.regions`.
`/v1/models` had no `datacenters` on 16 November 2026, so `regions` was empty for every model.
Model availability depends on the account tier and the regions enabled for it; a model outside
the account's tier returns 403 and reaches the app as `SCXError`.

## Images and video

Attachments go inline as base64 data URLs, in `image_url` and `video_url` content parts. A prompt
with no attachment stays a plain string. SCX's limits are 20 MB per image, JPEG or PNG, and
300 KB per video, MP4. `SCXLanguageModel.maximumImageBytes` and `maximumVideoBytes` hold them.
300 KB is SCX's video limit for now and may be raised later, and an app can raise
`maximumVideoBytes` for a model that takes more.

Inline is the only form that works on every vision model. On `gemma-4-31B-it` an https image URL
answers 502, an https video URL answers 400, and a `/v1/files` id answers 502. `GLM-5.3-Flash`
fetches an image URL correctly.

The real limits differ per model and `/v1/models` does not carry them yet. Measured on
4 November 2026 with inline base64:

| Model | Accepted | Refused |
|-------|----------|---------|
| `gemma-4-31B-it`, image | 19.0 MB | 20.0 MB and above |
| `gemma-4-31B-it`, MP4 | 325 KB | 458 KB and above |
| `GLM-5.3-Flash`, image | 21.1 MB | not found |

The refusals are 400s with no `param` and no size: "A request parameter is not accepted by this
model." for images and "The request was rejected as invalid." for video. A model that does not
take the content type answers 400 with "The request contains a content type this model does not
accept." The executor turns all of these into `unsupportedTranscriptContent`, adding the model,
the size and SCX's own message.

Apple's side has two separate declarations. `.vision` covers images and comes from
`input_modalities` containing `image`. Video has no capability case, so
`supportsDataAttachmentType` answers for it from `input_modalities` containing `video`, and the
framework checks that before a data attachment reaches the executor. Data attachments need
iOS 27.2 and the 27.2 SDK; the video code compiles out on older SDKs
(`canImport(FoundationModels, _version: 2.1)`).

`load` reads video support from `input_modalities`. `gemma-4-31B-it` and `Kimi-K3.1-Pro` list
video. The frames of a video count as input tokens, so a long clip can fill the context window.
SCX then answers 400 with `param` `messages`, which the executor maps to `contextSizeExceeded`. `Kimi-K3` lists text and image and refuses video. An answer about a video on
`Kimi-K3.1-Pro` took between 15 seconds and almost 4 minutes in tests, so keep `timeout` at its
default of 300 seconds or higher.

`/v1/models` lists `apex` with text and image input, and it answers 400 "Unsupported model" on
`/chat/completions`. It is a System One decision model with its own endpoint, `POST /v1/systemone`,
and `supported_features` of `systemone`, so `load` refuses it.

A text-only model does not refuse an image. MAGPiE accepts the part and answers as if nothing was
attached, so the executor refuses images itself on a model without `.vision`.

Every image is decoded and encoded again, as JPEG, or as PNG when it has an alpha channel. One path
then covers HEIC files, pixel buffers and rotated photos. `orientation` is applied to the pixels
before encoding. On watchOS there is no `ciImage`, so a rotated image goes as stored.

Attachments in instructions or tool output are refused with `unsupportedTranscriptContent`.
Labels from `Attachment.label(_:)` are not sent.

## max_tokens covers reasoning tokens

`max_tokens` caps reasoning plus content, and reasoning is emitted first. There is no parameter
that limits the two separately. On a reasoning model a tight cap can therefore consume the whole
allowance before any content is produced, returning empty content with `finish_reason: "length"`.
The recommended pattern is to leave `max_tokens` unset on reasoning models, or to set it well
above the expected reasoning length.

This matters through Apple's API because `GenerationOptions.maximumResponseTokens` maps straight
to `max_tokens`. An app that lowers it to control cost gets empty responses rather than short
ones. The README documents this for app developers.

## Reasoning

Reasoning models return reasoning as `reasoning_content` deltas in the stream, not as `<think>`
tags, so no tag parsing is needed. The executor routes those deltas to Apple's reasoning channel,
where they appear as reasoning entries in the session transcript.

`reasoning_effort` accepts `low`, `medium` and `high`, sent from `ContextOptions.reasoningLevel`
(`light`, `moderate`, `deep`). It is honoured by all reasoning models, and there is no other way
to control reasoning depth.

Some models populate `reasoning_content` only on the streaming path, leaving it empty in a
non-streaming response while still billing reasoning tokens. The package always streams, so this
does not affect it.

## Rate limits

Limits apply per organization and per model across three dimensions: requests per minute, tokens
per minute and tokens per day. Responses carry `X-RateLimit-Limit-RPM` and
`X-RateLimit-Remaining-RPM`, and the same pair for `-TPM` and `-TPD`, with the value `unlimited`
when uncapped. Budget-capped organizations also receive `X-Budget-*` headers. A 429 includes
`Retry-After` when a retry time is known, and the executor passes it to Apple as the reset date
on `rateLimited`. 429, 503 and 529 should all be retried with backoff.

## Structured outputs

`response_format: {"type": "json_schema"}` runs with `"strict": false`. Schema compliance is
therefore best effort, and Apple's guaranteed-schema contract is bridged on the package side:
Apple's framework parses and validates the result. Applications should validate critical paths
themselves.

Supported schema shapes are objects, arrays, `required` and `additionalProperties`. `json_object`
mode returns "Model did not output valid JSON" when the model produces something else.

## Guardrails and refusals

Two different shapes reach the client:

- **Model-level refusal.** A disallowed prompt is refused inline as a normal completion:
  `finish_reason: "stop"`, the refusal in `content`, the rationale in `reasoning_content`. This
  is indistinguishable from an ordinary answer at the protocol level, so it streams through as
  assistant text, which is Apple's documented fallback for provider refusals.
- **Platform Guardrails.** The stream ends with `finish_reason: "content_filter"`, which the
  executor maps to `LanguageModelError.guardrailViolation`. The live tests do not cover this
  path, because Guardrails are not configured on the test organization.

A separate `/moderations` endpoint (`opir-large`, returning `flagged` plus category scores) is
available as an opt-in classifier. It is an application-level choice and not part of the package.

## Reproducibility

`seed` is accepted and the executor sends it from Apple's random `SamplingMode` cases, but
reproducible output is not a supported guarantee and nothing in the package promises it.
`presence_penalty` and `frequency_penalty` are not sent, because Apple's API exposes no
equivalent.
