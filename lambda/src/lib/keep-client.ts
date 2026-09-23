/**
 * Keep push API client. `POST /alerts/event/{provider_type}` answers 202 once the event is
 * accepted for (possibly asynchronous) processing; 202 does not mean the alert is persisted.
 * The API key goes in X-API-KEY: Keep treats `Authorization: Bearer` as an OAuth token.
 */
import { Config, Context, Data, Duration, Effect, Layer } from "effect"
import { Secrets } from "./secrets.ts"

export class KeepError extends Data.TaggedError("KeepError")<{
  readonly status: number | undefined
  readonly cause: unknown
}> {}

export interface KeepAccepted {
  readonly status: number
  readonly taskName: string | undefined
}

export interface KeepClientShape {
  readonly postAlert: (fingerprint: string, payload: unknown) => Effect.Effect<KeepAccepted, KeepError>
}

export class KeepClient extends Context.Tag("KeepClient")<KeepClient, KeepClientShape>() {}

export const KeepClientLive = Layer.effect(
  KeepClient,
  Effect.gen(function* () {
    const baseUrl = yield* Config.string("KEEP_API_URL")
    const providerType = yield* Config.string("KEEP_PROVIDER_TYPE").pipe(Config.withDefault("prometheus"))
    const apiKeySecretId = yield* Config.string("KEEP_API_KEY_SECRET_ID")
    const timeout = yield* Config.duration("KEEP_REQUEST_TIMEOUT").pipe(Config.withDefault(Duration.seconds(10)))
    const secrets = yield* Secrets

    return {
      postAlert: (fingerprint, payload) =>
        Effect.gen(function* () {
          const apiKey = yield* secrets.get(apiKeySecretId).pipe(
            Effect.mapError((cause) => new KeepError({ status: undefined, cause })),
          )
          const url = new URL(`/alerts/event/${providerType}`, baseUrl)
          url.searchParams.set("fingerprint", fingerprint)
          const response = yield* Effect.tryPromise({
            try: (signal) =>
              fetch(url, {
                method: "POST",
                headers: { "content-type": "application/json", "x-api-key": apiKey },
                body: JSON.stringify(payload),
                signal,
              }),
            catch: (cause) => new KeepError({ status: undefined, cause }),
          }).pipe(
            Effect.timeoutFail({ duration: timeout, onTimeout: () => new KeepError({ status: undefined, cause: "timeout" }) }),
          )
          const text = yield* Effect.promise(() => response.text())
          if (response.status !== 200 && response.status !== 202) {
            return yield* new KeepError({ status: response.status, cause: text.slice(0, 500) })
          }
          const taskName = yield* Effect.try(() => (JSON.parse(text) as { task_name?: string }).task_name).pipe(
            Effect.orElseSucceed(() => undefined),
          )
          return { status: response.status, taskName }
        }),
    }
  }),
)
