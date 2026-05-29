'use strict';

'require dom';

'require podman.ui as podmanUI';
'require podman.view as podmanView';
'require podman.utils as podmanUtil';

return podmanView.tabContent.extend({
	tab: 'stats',
	container: null,

	render(container) {
		this.container = container;

		if (!this.container.isRunning()) {
			return this.warningContent(_('Container is not running'));
		}

		return this.renderTabContent(_('Statistics'), [
			this.renderStatsTable(),
		]);
	},

	onTabActive() {
		this._startStream();

		// Pause the stream while the browser tab is hidden (frees the uhttpd slot
		// and the Podman stream for a forgotten background tab); resume on return.
		if (!this._visHandler) {
			this._visHandler = () => document.hidden ? this._stopStream() : this._startStream();
			document.addEventListener('visibilitychange', this._visHandler);
		}
		// Best-effort clean close on full page unload/refresh.
		if (!this._unloadHandler) {
			this._unloadHandler = () => this._stopStream();
			window.addEventListener('beforeunload', this._unloadHandler);
		}
	},

	onTabInactive() {
		this._stopStream();
		if (this._visHandler) {
			document.removeEventListener('visibilitychange', this._visHandler);
			this._visHandler = null;
		}
		if (this._unloadHandler) {
			window.removeEventListener('beforeunload', this._unloadHandler);
			this._unloadHandler = null;
		}
	},

	_startStream() {
		if (!this.container || !this.container.isRunning() || this.statsStream || document.hidden) {
			return;
		}
		this.statsStream = this.container.streamStatsViaSSE((stats) => {
			console.log('stats', stats);
			this.updateStatsDisplay(stats);
		}, 2);
	},

	_stopStream() {
		if (!this.statsStream) return;
		this.statsStream.stop();
		this.statsStream = null;
	},

	renderStatsTable() {
		const table = new podmanUI.TableList();

		table
			.addRow(_('CPU Usage'),    '-', { 'data-stat': 'cpu' })
			.addRow(_('Memory Usage'), '-', { 'data-stat': 'memory' })
			.addRow(_('Memory Limit'), '-', { 'data-stat': 'memory-limit' })
			.addRow(_('Memory %'),     '-', { 'data-stat': 'memory-percent' })
			.addRow(_('Network I/O'),  '-', { 'data-stat': 'network-io' })
			.addRow(_('Block I/O'),    '-', { 'data-stat': 'block-io' })
			.addRow(_('PIDs'),         '-', { 'data-stat': 'pids' })
		;

		return table.render();
	},

	updateStatsDisplay(stats) {
		if (!stats) return;

		if (!this.statElements) {
			this.statElements = {};
			for (const key of ['cpu', 'memory', 'memory-limit', 'memory-percent', 'network-io', 'block-io', 'pids']) {
				this.statElements[key] = document.querySelector(`[data-stat="${key}"] td:last-of-type`);
			}
		}

		const updates = [
			['cpu',            stats.CPU != null ? stats.CPU.toFixed(2) + '%' : '-'],
			['memory',         podmanUtil.format.bytes(stats.MemUsage) || '-'],
			['memory-limit',   podmanUtil.format.bytes(stats.MemLimit) || '-'],
			['memory-percent', stats.MemPerc != null ? stats.MemPerc.toFixed(2) + '%' : '-'],
			['network-io',     this._formatNetworkIO(stats.Network)],
			['block-io',       this._formatBlockIO(stats.BlockInput, stats.BlockOutput)],
			['pids',           stats.PIDs],
		];

		for (const [key, value] of updates) {
			if (this.statElements[key])
				dom.content(this.statElements[key], value);
		}
	},

	_formatNetworkIO(networks) {
		const parts = Object.keys(networks || {}).map((iface) => {
			const net = networks[iface];
			return `${iface}: ↓ ${podmanUtil.format.bytes(net.RxBytes)} / ↑ ${podmanUtil.format.bytes(net.TxBytes)}`;
		});

		if (parts.length === 0) return '-';

		return parts.reduce((nodes, part, i) => {
			if (i > 0) nodes.push(E('br'));
			nodes.push(part);
			return nodes;
		}, []);
	},

	_formatBlockIO(blockInput, blockOutput) {
		return _('Read: %s / Write: %s').format(
			podmanUtil.format.bytes(blockInput || 0),
			podmanUtil.format.bytes(blockOutput || 0)
		);
	}
});
