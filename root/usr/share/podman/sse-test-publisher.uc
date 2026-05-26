#!/usr/bin/env ucode
// TEST-ONLY harness for evaluating uhttpd's /ubus/subscribe/ SSE transport.
// Publishes the ubus object 'podman_ssetest' and emits a small 'tick'
// notification every second. uhttpd subscribes on behalf of a browser client;
// the test view (view/podman/ssetest.js) consumes the event-stream and shows
// per-event arrival gaps so we can SEE whether small writes are coalesced.
//
// Run on the router (foreground to watch, or backgrounded):
//   ucode /usr/share/podman/sse-test-publisher.uc
//   ucode /usr/share/podman/sse-test-publisher.uc >/tmp/sse-pub.log 2>&1 &
//
// Remove after testing (this file + the ACL grant + the menu/view entries).
'use strict';

import { connect } from 'ubus';
import * as uloop from 'uloop';

const conn = connect();
if (!conn) {
	warn('[sse-test] ubus connect failed\n');
	exit(1);
}

let n = 0;

// Declared up front: publish() invokes the subscribe callback synchronously
// during registration, so a `const obj = publish(...)` would hit it in the TDZ.
let obj;
obj = conn.publish('podman_ssetest', {
	// A trivial method so the object is well-formed; not used by the test.
	ping: {
		call: () => ({ pong: time() }),
		args: {}
	}
}, () => {
	// Fires when uhttpd subscribes / unsubscribes on behalf of a client.
	// Do NOT touch `obj` here - it may still be unassigned on the first call.
	warn('[sse-test] subscriber change\n');
});

if (!obj) {
	warn('[sse-test] publish failed\n');
	exit(1);
}

warn('[sse-test] published podman_ssetest; emitting tick every 1000ms\n');

uloop.init();

let tick;
tick = () => {
	// ~50-byte payload, well under the ~1.1KB threshold we are probing for.
	obj.notify('tick', { n: n++, ts: time() });
	// Periodic subscriber-presence log (safe here: obj is assigned).
	if (n % 5 == 0)
		warn(sprintf('[sse-test] n=%d has_subscribers=%s\n', n, obj.subscribed()));
	uloop.timer(1000, tick);
};
uloop.timer(1000, tick);

uloop.run();
