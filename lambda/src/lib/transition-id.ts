import { createHash } from "node:crypto"
import type { AlertmanagerAlert } from "./schema.ts"

/**
 * Idempotency key of one alert state transition. Used as the Journal partition key and the SQS
 * FIFO MessageDeduplicationId. Re-notifications of the same firing alert map to the same id; the
 * resolved transition gets a different id because the status differs.
 */
export const transitionId = (source: string, alert: AlertmanagerAlert): string =>
  createHash("sha256").update([source, alert.fingerprint, alert.status, alert.startsAt].join("|")).digest("hex")

/**
 * FIFO MessageGroupId and Keep fingerprint. Alertmanager fingerprints are hashes of the label set,
 * so the source is prepended to keep identical label sets from different clusters apart.
 */
export const scopedFingerprint = (source: string, fingerprint: string): string => `${source}:${fingerprint}`
