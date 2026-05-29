'use strict';

'require dom';

'require podman.ui as podmanUI';
'require podman.view as podmanView';

return podmanView.tabContent.extend({
	tab: 'ps',
	container: null,

	render(container) {
		this.container = container;

		if (!this.container.isRunning()) {
			return this.warningContent(_('Container is not running'));
		}

		this.tableContent = E('div', { class: 'ps-table-content' }, []);

		return this.renderTabContent('', [
			this.tableContent,
		]);
	},

	onTabActive() {
		this._startStream();

		// Pause while the browser tab is hidden; resume on return.
		if (!this._visHandler) {
			this._visHandler = () => document.hidden ? this._stopStream() : this._startStream();
			document.addEventListener('visibilitychange', this._visHandler);
		}
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
		if (!this.container || !this.container.isRunning() || this.processStream || document.hidden) {
			return;
		}
		this.processStream = this.container.streamTopViaSSE((ps) => {
			this.updateProcessList(ps);
		}, 2);
	},

	_stopStream() {
		if (!this.processStream) return;
		this.processStream.stop();
		this.processStream = null;
	},

	updateProcessList(ps) {
		if (!ps || !ps.Titles || !ps.Processes || ps.Titles.length === 0) {
			return;
		}

		const psTable = new podmanUI.Table();
		const columnWidth = `width: ${100 / ps.Titles.length}%;`;
		const timeIndex = ps.Titles.indexOf('ELAPSED');

		ps.Titles.forEach((title) => {
			psTable.addHeader(_(title), { style: columnWidth });
		});

		ps.Processes.forEach((process) => {
			psTable.addRow(process.map((detail, i) => ({
				inner: i === timeIndex ? this._formatElapsedTime(detail) : detail
			})));
		});

		dom.content(this.tableContent, psTable.render());
	},

	_formatElapsedTime(timeStr) {
		if (!timeStr) return '-';

		const result = [];
		const pattern = /(\d+(?:\.\d+)?)([ydhms])/g;
		let match;

		while ((match = pattern.exec(timeStr)) !== null) {
			let value = parseFloat(match[1]);
			const unit = match[2];

			if (unit === 's' && value > 1000) {
				value = Math.floor(value / 1000000000);

				if (value >= 60) {
					const mins = Math.floor(value / 60);
					const secs = value % 60;
					if (mins > 0) result.push(`${mins}m`);
					if (secs > 0) result.push(`${secs}s`);
					continue;
				}
			} else {
				value = Math.floor(value);
			}

			if (unit === 's' || unit === 'm') {
				result.push(String(value).padStart(2, '0') + unit);
			} else {
				result.push(value + unit);
			}
		}

		return result.length > 0 ? result.join('') : timeStr;
	}
});
