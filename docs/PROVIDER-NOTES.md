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
| 400 | `invalid_request_error` | bad request; `param` names the field | `param == "messages"` → `contextSizeExceeded`, else propagates |
| 401 | `authentication_error` | bad key | propagates |
| 402 | `insufficient_credit` | organization out of credit | propagates |
| 403 | `permission_error` | key lacks access to the model | propagates |
| 404 | `not_found_error` | unknown resource or model | propagates |
| 413 | `invalid_request_error` | body too large | `contextSizeExceeded` |
| 429 | `rate_limit_error` / `quota_exceeded` | rate or budget limit hit | `rateLimited` |
| 500 | `api_error` | server error | propagates |
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

Each entry also carries its datacenter regions as country codes, exposed as `ModelInfo.regions`.
Model availability depends on the account tier and the regions enabled for it; a model outside
the account's tier returns 403 and reaches the app as `SCXError`.

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
on `rateLimited`. Both 429 and 529 should be retried with backoff.

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
