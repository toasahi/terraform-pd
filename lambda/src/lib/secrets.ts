import { GetSecretValueCommand } from "@aws-sdk/client-secrets-manager"
import { Cache, Context, Duration, Effect, Layer } from "effect"
import { AwsError, SecretsManager } from "./aws.ts"

export interface SecretsShape {
  /** Secret string, cached per execution environment for five minutes (rotation-friendly). */
  readonly get: (secretId: string) => Effect.Effect<string, AwsError>
}

export class Secrets extends Context.Tag("Secrets")<Secrets, SecretsShape>() {}

export const SecretsLive = Layer.effect(
  Secrets,
  Effect.gen(function* () {
    const client = yield* SecretsManager
    const cache = yield* Cache.make({
      capacity: 16,
      timeToLive: Duration.minutes(5),
      lookup: (secretId: string) =>
        Effect.tryPromise({
          try: () => client.send(new GetSecretValueCommand({ SecretId: secretId })),
          catch: (cause) => new AwsError({ operation: "secretsmanager:GetSecretValue", cause }),
        }).pipe(
          Effect.flatMap((out) =>
            out.SecretString === undefined
              ? Effect.fail(new AwsError({ operation: "secretsmanager:GetSecretValue", cause: "SecretString is empty" }))
              : Effect.succeed(out.SecretString),
          ),
        ),
    })
    return { get: (secretId) => cache.get(secretId) }
  }),
)
