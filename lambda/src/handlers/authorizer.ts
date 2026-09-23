/**
 * API Gateway REST REQUEST authorizer. Each alert source (e.g. prod / management EKS Alertmanager)
 * sends `Authorization: Bearer <token>`; the secret stores sha256 hex digests of the valid tokens
 * per source (a list allows zero-downtime rotation). The policy is scoped to the exact methodArn,
 * so a cached decision for one source can never authorize another source's path.
 */
import { createHash, timingSafeEqual } from "node:crypto"
import { Config, Effect, Layer, Option, Schema } from "effect"
import { SecretsManager } from "../lib/aws.ts"
import { RequestAuthorizerEvent, SourceTokenDigests } from "../lib/schema.ts"
import { Secrets, SecretsLive } from "../lib/secrets.ts"

const sha256 = (value: string) => createHash("sha256").update(value).digest()

export const verifyToken = (digests: SourceTokenDigests, source: string, token: string): boolean => {
  const expected = digests[source]
  if (expected === undefined) return false
  const actual = sha256(token)
  // Compare against every digest without short-circuiting.
  return (typeof expected === "string" ? [expected] : expected).reduce((ok, hex) => {
    const candidate = Buffer.from(hex, "hex")
    return (candidate.length === actual.length && timingSafeEqual(candidate, actual)) || ok
  }, false)
}

export const bearerToken = (headers: Readonly<Record<string, string>> | null | undefined): Option.Option<string> =>
  Option.fromNullable(headers).pipe(
    Option.flatMap((h) =>
      Option.fromNullable(Object.entries(h).find(([name]) => name.toLowerCase() === "authorization")?.[1]),
    ),
    Option.flatMap((value) => {
      const match = /^Bearer\s+(\S+)$/i.exec(value.trim())
      return match?.[1] === undefined ? Option.none() : Option.some(match[1])
    }),
  )

export const policy = (principalId: string, effect: "Allow" | "Deny", resource: string) => ({
  principalId,
  policyDocument: {
    Version: "2012-10-17",
    Statement: [{ Action: "execute-api:Invoke", Effect: effect, Resource: resource }],
  },
  context: { source: principalId },
})

export const handle = (event: unknown) =>
  Effect.gen(function* () {
    const secretId = yield* Config.string("SOURCE_TOKENS_SECRET_ID")
    const secrets = yield* Secrets
    const request = yield* Schema.decodeUnknown(RequestAuthorizerEvent)(event)
    const source = request.pathParameters?.source ?? ""
    const token = bearerToken(request.headers)

    if (source === "" || Option.isNone(token)) {
      yield* Effect.logWarning("authorizer: missing source or bearer token", { source })
      return policy(source || "anonymous", "Deny", request.methodArn)
    }
    const digests = yield* secrets.get(secretId).pipe(Effect.flatMap(Schema.decodeUnknown(Schema.parseJson(SourceTokenDigests))))
    const allowed = verifyToken(digests, source, token.value)
    if (!allowed) yield* Effect.logWarning("authorizer: token rejected", { source })
    return policy(source, allowed ? "Allow" : "Deny", request.methodArn)
  })

export const layer = SecretsLive.pipe(Layer.provide(SecretsManager.Live))
