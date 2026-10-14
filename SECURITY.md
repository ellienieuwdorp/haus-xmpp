# Security policy

Haus XMPP is an end-to-end encrypted messenger. A flaw can expose people's conversations, so please report it privately and give us time to fix it before you publish.

## How to report

Use GitHub private vulnerability reporting: **Security > Report a vulnerability** in this repository. Only the maintainers can read the report.

Include the commit or app version you tested, the platform and OS version, the steps to reproduce, and what an attacker gains. Do not send real conversations or someone else's data; a proof of concept against test accounts is enough.

We acknowledge reports within 5 working days and aim to ship a fix within 90 days. We'll tell you when the fix is out and credit you in the release notes unless you prefer otherwise. If you think a report is being ignored, say so in the same thread.

## In scope

- OMEMO: key and trust handling, identity changes, device list handling, decryption of messages from untrusted devices, replay or reordering, anything that shows an unauthenticated message as authenticated.
- Any path where content is sent unencrypted while the conversation is shown as encrypted.
- Leaks of message content, keys or credentials into logs, notifications, push payloads, backups, crash reports or other apps.
- XMPP parsing and stream handling that a malicious server or contact can exploit (crashes count when an attacker can trigger them remotely).
- TLS and certificate validation, SASL authentication.
- Local storage: the message database, keychain items, attachment caches.

## Out of scope

- Vulnerabilities in a third-party XMPP server or another client. Please report those upstream. If the issue is in libomemo-c, report it to the [libomemo-c project](https://github.com/dino/libomemo-c) and tell us too.
- Attacks that need an unlocked device the attacker already controls, or a jailbroken device.
- Missing hardening without a demonstrated impact.
- Development-only code paths that are compiled out of release builds (`#if DEBUG`).

## Safe harbour

We will not pursue legal action against good-faith research that follows this policy, avoids accessing other people's data, and does not disrupt servers you do not own.
