import type { Context as LambdaContext } from "aws-lambda"
import { Effect, Layer, Logger, ManagedRuntime } from "effect"

export type LambdaHandler = (event: unknown, context: LambdaContext) => Promise<unknown>

/**
 * Adapts an Effect handler to the Node.js Lambda handler signature.
 *
 * The layer is built lazily on the first invocation and then reused for the lifetime of the
 * execution environment. Failures are logged and re-thrown, so Lambda records a failed invocation:
 * SQS redelivers the batch and API Gateway answers 5xx instead of silently succeeding.
 */
export const makeLambdaHandler = <R, E, LE>(
  handle: (event: unknown, context: LambdaContext) => Effect.Effect<unknown, E, R>,
  layer: Layer.Layer<R, LE>,
): LambdaHandler => {
  let runtime: ManagedRuntime.ManagedRuntime<R, LE> | undefined
  return (event, context) => {
    runtime ??= ManagedRuntime.make(Layer.merge(layer, Logger.json))
    return runtime.runPromise(
      handle(event, context).pipe(
        Effect.tapErrorCause((cause) => Effect.logError("invocation failed", cause)),
        Effect.annotateLogs({ awsRequestId: context.awsRequestId }),
      ),
    )
  }
}
