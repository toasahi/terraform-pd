import { describe, expect, test } from "vitest"
import { createHash } from "node:crypto"
import { Effect, Layer, Option } from "effect"
import { bearerToken, handle, verifyToken } from "../src/handlers/authorizer.ts"
import { Secrets } from "../src/lib/secrets.ts"
import { withEnv } from "./helpers.ts"

const digest = (token: string) => createHash("sha256").update(token).digest("hex")
const digests = { prod: [digest("new-token"), digest("old-token")], management: digest("mgmt-token") }
const methodArn = "arn:aws:execute-api:ap-northeast-1:123456789012:abc123/v1/POST/v1/alerts/prod"

const run = (event: unknown) =>
  Effect.runPromise(
    handle(event).pipe(
      Effect.provide(
        Layer.mergeAll(
          Layer.succeed(Secrets, { get: () => Effect.succeed(JSON.stringify(digests)) }),
          withEnv({ SOURCE_TOKENS_SECRET_ID: "secret" }),
        ),
      ),
    ),
  )

describe("verifyToken", () => {
  test("accepts any configured digest for the source (rotation)", () => {
    expect(verifyToken(digests, "prod", "new-token")).toBe(true)
    expect(verifyToken(digests, "prod", "old-token")).toBe(true)
  })

  test("rejects a token of another source and unknown sources", () => {
    expect(verifyToken(digests, "prod", "mgmt-token")).toBe(false)
    expect(verifyToken(digests, "staging", "mgmt-token")).toBe(false)
  })
})

describe("bearerToken", () => {
  test("reads the Authorization header case-insensitively", () => {
    expect(bearerToken({ authorization: "Bearer abc" })).toEqual(Option.some("abc"))
    expect(bearerToken({ Authorization: "bearer  abc " })).toEqual(Option.some("abc"))
  })

  test("ignores other schemes", () => {
    expect(Option.isNone(bearerToken({ Authorization: "Basic abc" }))).toBe(true)
    expect(Option.isNone(bearerToken(undefined))).toBe(true)
  })
})

describe("authorizer handler", () => {
  test("allows a valid token, scoped to the exact methodArn", async () => {
    const result = await run({ methodArn, headers: { Authorization: "Bearer new-token" }, pathParameters: { source: "prod" } })
    expect(result.policyDocument.Statement[0]).toEqual({ Action: "execute-api:Invoke", Effect: "Allow", Resource: methodArn })
    expect(result.context.source).toBe("prod")
  })

  test("denies an invalid or missing token", async () => {
    const invalid = await run({ methodArn, headers: { Authorization: "Bearer nope" }, pathParameters: { source: "prod" } })
    const missing = await run({ methodArn, headers: {}, pathParameters: { source: "prod" } })
    expect(invalid.policyDocument.Statement[0]?.Effect).toBe("Deny")
    expect(missing.policyDocument.Statement[0]?.Effect).toBe("Deny")
  })
})
