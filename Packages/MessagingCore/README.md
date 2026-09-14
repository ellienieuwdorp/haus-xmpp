# MessagingCore

Small application-owned sending policy over MessageStore. No external dependencies beyond our local package and system SQLite. `OutboxSender` serializes one in-process drain, claims durable queued rows before transport, and preserves uncertain sends for explicit retry.

Cancellation after claim but before calling the transport returns the claim to queued. Once transport was invoked, success or failure becomes unconfirmed: neither proves recipient delivery. On write error the drain stops. The app disconnects that session and restarts pending work only after another connection. Attempt tokens fence stale storage updates. One store and sender owner per database is required; this is not yet an app/notification-extension coordination protocol.

`swift test --package-path Packages/MessagingCore` covers persist-before-wire ordering, explicit retries preserving the same ID, no automatic replay, socket failures and cancellation on both sides of claim.
