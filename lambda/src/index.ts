/**
 * Lambda entry point. One bundle serves all four functions; each function's `handler` attribute
 * selects its export (index.authorizer, index.ingest, index.router, index.dispatcher).
 */
import * as authorizerHandler from "./handlers/authorizer.ts"
import * as dispatcherHandler from "./handlers/dispatcher.ts"
import * as ingestHandler from "./handlers/ingest.ts"
import * as routerHandler from "./handlers/router.ts"
import { makeLambdaHandler } from "./runtime/handler.ts"

export const authorizer = makeLambdaHandler(authorizerHandler.handle, authorizerHandler.layer)
export const ingest = makeLambdaHandler(ingestHandler.handle, ingestHandler.layer)
export const router = makeLambdaHandler(routerHandler.handle, routerHandler.layer)
export const dispatcher = makeLambdaHandler(dispatcherHandler.handle, dispatcherHandler.layer)
