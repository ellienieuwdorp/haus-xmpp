# xmpp.haus

The project website: a landing page, the privacy policy and the support page. Plain HTML and CSS in `public/`, served by Cloudflare Workers static assets on `xmpp.haus` and `www.xmpp.haus`.

Every page loads the Umami tracker from `stats.wavfeed.com` (cookieless page views, described in the privacy policy). Its `data-domains` limits counting to `xmpp.haus` and `www.xmpp.haus`, so a local preview or a copy of the site on another host sends nothing. A new page needs the same `<script>` line in its `<head>`.

Deploy with a Cloudflare API token that can edit Workers scripts and routes:

```sh
npx wrangler@4.151.0 deploy
```
