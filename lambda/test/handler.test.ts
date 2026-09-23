import type { Context as LambdaContext } from "aws-lambda"
import { Context, Effect, Layer } from "effect"
import { describe, expect, test } from "vitest"
import { makeLambdaHandler } from "../src/runtime/handler.ts"

class Counter extends Context.Tag("Counter")<Counter, { readonly next: () => number }>() {}

const context = { awsRequestId: "req-1" } as LambdaContext

const counterLayer = () => {
  let builds = 0
  let calls = 0
  const layer = Layer.sync(Counter, () => {
    builds += 1
    return { next: () => ++calls }
  })
  return { layer, builds: () => builds }
}

describe("makeLambdaHandler", () => {
  test("resolves with the handler result and builds the layer once per execution environment", async () => {
    const { layer, builds } = counterLayer()
    const handler = makeLambdaHandler(
      (event) => Effect.map(Counter, (counter) => ({ event, call: counter.next() })),
      layer,
    )
    expect(await handler({ n: 1 }, context)).toEqual({ event: { n: 1 }, call: 1 })
    expect(await handler({ n: 2 }, context)).toEqual({ event: { n: 2 }, call: 2 })
    expect(builds()).toBe(1)
  })

  test("rejects on failure so Lambda records a failed invocation", async () => {
    const { layer } = counterLayer()
    const handler = makeLambdaHandler(() => Effect.fail(new Error("kaboom")), layer)
    await expect(handler({}, context)).rejects.toThrow("kaboom")
  })
})
