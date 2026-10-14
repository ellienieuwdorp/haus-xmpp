# xmpp.haus

The project website: a landing page, the privacy policy and the support page. Plain HTML and CSS in `public/`, served by Cloudflare Workers static assets on `xmpp.haus` and `www.xmpp.haus`.

Deploy with a Cloudflare API token that can edit Workers scripts and routes:

```sh
npx wrangler@4.151.0 deploy
```
