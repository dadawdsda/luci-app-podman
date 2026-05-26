'use strict';

'require view';
'require ui';

// TEST-ONLY view: probes uhttpd's /ubus/subscribe/<object> SSE transport.
// Consumes the text/event-stream from the 'podman_ssetest' publisher via
// fetch()+ReadableStream (authed with the Bearer session id, since EventSource
// cannot set headers) and logs each event with its client-side arrival gap.
//
// What to look for:
//   - Steady ~1000ms gaps  => no write coalescing (the padding hack is unneeded)
//   - Connection open >60s  => no script_timeout hard cap (reconnect machinery unneeded)
//   - Drop after a quiet gap => idle network_timeout (a small heartbeat is needed)
return view.extend({
	abort: null,

	render() {
		const OBJECT = 'podman_ssetest';
		const url = '/ubus/subscribe/' + OBJECT;

		const stats = E('div', { 'style': 'margin:8px 0;font-weight:bold' }, '—');
		const log = E('div', {
			'style': 'font-family:monospace;white-space:pre-wrap;max-height:60vh;' +
				'overflow:auto;border:1px solid #ccc;padding:8px;background:#fafafa'
		});

		let count = 0, startTs = 0, lastTs = 0;

		const append = (line) => {
			log.appendChild(E('div', {}, line));
			log.scrollTop = log.scrollHeight;
		};

		const start = async () => {
			if (this.abort) return;
			count = 0; startTs = Date.now(); lastTs = startTs;
			this.abort = new AbortController();
			append('→ connecting ' + url + '  (sid=' + (L.env.sessionid || '—') + ')');

			try {
				const resp = await fetch(url, {
					headers: { 'Authorization': 'Bearer ' + L.env.sessionid },
					signal: this.abort.signal,
				});
				append('← HTTP ' + resp.status + '  content-type=' +
					(resp.headers.get('content-type') || '—'));
				if (!resp.ok || !resp.body) {
					append('✗ unusable response (status ' + resp.status + ')');
					this.abort = null;
					return;
				}

				const reader = resp.body.getReader();
				const dec = new TextDecoder();
				let buf = '';

				while (true) {
					const { value, done } = await reader.read();
					if (done) {
						append('✗ server closed stream after ' +
							((Date.now() - startTs) / 1000).toFixed(1) + 's');
						break;
					}
					buf += dec.decode(value, { stream: true });

					let idx;
					while ((idx = buf.indexOf('\n\n')) >= 0) {
						const block = buf.slice(0, idx);
						buf = buf.slice(idx + 2);

						const now = Date.now();
						const gap = now - lastTs;
						lastTs = now;
						count++;

						let ev = '', data = '';
						for (const l of block.split('\n')) {
							if (l.indexOf('event:') === 0) ev = l.slice(6).trim();
							else if (l.indexOf('data:') === 0) data = l.slice(5).trim();
						}

						append('#' + count + '  +' + gap + 'ms  event=' + ev + '  data=' + data);
						stats.textContent = 'events: ' + count +
							'  |  open: ' + ((now - startTs) / 1000).toFixed(1) + 's' +
							'  |  last gap: ' + gap + 'ms';
					}
				}
			} catch (e) {
				append('✗ ' + (e.name === 'AbortError' ? 'aborted by user' : (e.message || e)));
			} finally {
				this.abort = null;
			}
		};

		const stop = () => { if (this.abort) this.abort.abort(); };

		return E('div', {}, [
			E('h2', {}, _('SSE Subscribe Transport Test')),
			E('p', {}, _('Subscribes to ubus object "%s" via /ubus/subscribe/ and logs each event with its client-side arrival gap. Steady ~1000ms gaps mean no write coalescing; staying open past 60s means no script_timeout cap.').format(OBJECT)),
			E('div', { 'style': 'margin:8px 0' }, [
				E('button', { 'class': 'btn cbi-button-action', 'click': start }, _('Start')),
				' ',
				E('button', { 'class': 'btn', 'click': stop }, _('Stop')),
			]),
			stats,
			log,
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null,
});
