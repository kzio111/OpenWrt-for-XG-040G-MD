'use strict';
'require view';
'require poll';
'require rpc';
'require ui';

var callNpuStatus = rpc.declare({
	object: 'luci.airoha_npu',
	method: 'getStatus'
});

var callPpeEntries = rpc.declare({
	object: 'luci.airoha_npu',
	method: 'getPpeEntries'
});

var callSetGovernor = rpc.declare({
	object: 'luci.airoha_npu',
	method: 'setGovernor',
	params: ['governor']
});

var callSetMaxFreq = rpc.declare({
	object: 'luci.airoha_npu',
	method: 'setMaxFreq',
	params: ['freq']
});

var callSetOverclock = rpc.declare({
	object: 'luci.airoha_npu',
	method: 'setOverclock',
	params: ['freq_mhz']
});

function formatBytes(bytes) {
	if (bytes === 0) return '0 B';
	var k = 1024;
	var sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
	var i = Math.floor(Math.log(bytes) / Math.log(k));
	return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
}

function formatPackets(packets) {
	if (packets === 0) return '0';
	if (packets >= 1000000) return (packets / 1000000).toFixed(2) + 'M';
	if (packets >= 1000) return (packets / 1000).toFixed(2) + 'K';
	return packets.toString();
}

function formatFreqMHz(khz) {
	if (!khz || khz === 0) return 'N/A';
	return (khz / 1000).toFixed(0) + ' MHz';
}

function calcTotalMemory(memRegions) {
	var totalMemory = 0;
	memRegions.forEach(function(region) {
		var sizeStr = region.size || '';
		var match = sizeStr.match(/(\d+)\s*(KiB|MiB|GiB|KB|MB|GB)/i);
		if (match) {
			var size = parseInt(match[1]);
			var unit = match[2].toUpperCase();
			if (unit === 'KIB' || unit === 'KB') totalMemory += size;
			else if (unit === 'MIB' || unit === 'MB') totalMemory += size * 1024;
			else if (unit === 'GIB' || unit === 'GB') totalMemory += size * 1024 * 1024;
		}
	});
	return totalMemory >= 1024 ? (totalMemory / 1024).toFixed(0) + ' MiB' : totalMemory + ' KiB';
}

function renderGovernorSelect(availGovs, activeGov) {
	var govs = (availGovs || '').trim().split(/\s+/).filter(function(g) { return g.length > 0; });
	if (govs.length === 0) return E('span', {}, 'N/A');

	var select = E('select', {
		'id': 'cpu-governor-select',
		'class': 'cbi-input-select',
		'style': 'min-width:140px',
		'change': function(ev) {
			var gov = ev.target.value;
			ev.target.disabled = true;
			callSetGovernor(gov).then(function(res) {
				ev.target.disabled = false;
				if (res && res.error) {
					ui.addNotification(null, E('p', {}, _('Failed to set governor: ') + res.error), 'error');
				}
			}).catch(function() {
				ev.target.disabled = false;
			});
		}
	}, govs.map(function(gov) {
		return E('option', { 'value': gov, 'selected': gov === activeGov ? '' : null }, gov);
	}));

	return select;
}

function renderMaxFreqSelect(availFreqs, currentMax) {
	var freqs = (availFreqs || '').trim().split(/\s+/).filter(function(f) { return f.length > 0; });
	if (freqs.length === 0) return E('span', {}, 'N/A');

	var select = E('select', {
		'id': 'cpu-maxfreq-select',
		'class': 'cbi-input-select',
		'style': 'min-width:140px',
		'change': function(ev) {
			var freq = ev.target.value;
			ev.target.disabled = true;
			callSetMaxFreq(parseInt(freq)).then(function(res) {
				ev.target.disabled = false;
				if (res && res.error) {
					ui.addNotification(null, E('p', {}, _('Failed to set max frequency: ') + res.error), 'error');
				}
			}).catch(function() {
				ev.target.disabled = false;
			});
		}
	}, freqs.map(function(freq) {
		var mhz = (parseInt(freq) / 1000).toFixed(0) + ' MHz';
		return E('option', {
			'value': freq,
			'selected': parseInt(freq) === parseInt(currentMax) ? '' : null
		}, mhz);
	}));

	return select;
}

function renderFreqBar(hwFreq, minFreq, maxFreq, pllFreqMhz) {
	if (!maxFreq || maxFreq === 0) return E('span', {}, 'N/A');

	var displayMax = maxFreq;
	var displayFreq = hwFreq;

	// If overclocked beyond OPP table, adjust the bar range
	if (pllFreqMhz > 0 && (pllFreqMhz * 1000) > maxFreq) {
		displayMax = pllFreqMhz * 1000;
		displayFreq = pllFreqMhz * 1000;
	}

	var pct = Math.round(((displayFreq - minFreq) / (displayMax - minFreq)) * 100);
	if (pct < 0) pct = 0;
	if (pct > 100) pct = 100;

	var isOverclocked = pllFreqMhz > 0 && (pllFreqMhz * 1000) > maxFreq;
	var barColor = isOverclocked
		? 'linear-gradient(90deg,#e65100,#ff9800)'
		: 'linear-gradient(90deg,#2e7d32,#66bb6a)';

	var freqLabel = isOverclocked ? (pllFreqMhz + ' MHz (OC)') : formatFreqMHz(hwFreq);

	return E('div', { 'id': 'cpu-freq-bar-wrap', 'style': 'display:flex;align-items:center;gap:10px' }, [
		E('span', { 'style': 'color:#aaa;font-size:90%' }, formatFreqMHz(minFreq)),
		E('div', { 'style': 'flex:1;background:#333;border-radius:4px;height:22px;position:relative;min-width:180px;max-width:350px' }, [
			E('div', { 'id': 'cpu-freq-fill', 'style': 'background:' + barColor + ';height:100%;border-radius:4px;width:' + pct + '%;transition:width 0.5s ease' }),
			E('span', { 'id': 'cpu-freq-text', 'style': 'position:absolute;top:0;left:0;right:0;bottom:0;display:flex;align-items:center;justify-content:center;font-weight:bold;font-size:13px;color:#fff;text-shadow:0 1px 2px rgba(0,0,0,0.6)' },
				freqLabel),
		]),
		E('span', { 'id': 'cpu-freq-max-label', 'style': 'color:#aaa;font-size:90%' }, formatFreqMHz(displayMax))
	]);
}

function updateFreqBar(hwFreq, minFreq, maxFreq, pllFreqMhz) {
	var textEl = document.getElementById('cpu-freq-text');
	var fillEl = document.getElementById('cpu-freq-fill');
	var maxLabel = document.getElementById('cpu-freq-max-label');

	var displayMax = maxFreq;
	var displayFreq = hwFreq;
	var isOverclocked = pllFreqMhz > 0 && (pllFreqMhz * 1000) > maxFreq;

	if (isOverclocked) {
		displayMax = pllFreqMhz * 1000;
		displayFreq = pllFreqMhz * 1000;
	}

	if (textEl) {
		textEl.textContent = isOverclocked ? (pllFreqMhz + ' MHz (OC)') : formatFreqMHz(hwFreq);
	}
	if (fillEl && displayMax > 0) {
		var pct = Math.round(((displayFreq - minFreq) / (displayMax - minFreq)) * 100);
		if (pct < 0) pct = 0;
		if (pct > 100) pct = 100;
		fillEl.style.width = pct + '%';
		fillEl.style.background = isOverclocked
			? 'linear-gradient(90deg,#e65100,#ff9800)'
			: 'linear-gradient(90deg,#2e7d32,#66bb6a)';
	}
	if (maxLabel) {
		maxLabel.textContent = formatFreqMHz(displayMax);
	}
}

function renderOverclockControls() {
	var input = E('input', {
		'id': 'oc-freq-input',
		'type': 'number',
		'min': '500',
		'max': '1600',
		'step': '50',
		'value': '1400',
		'class': 'cbi-input-text',
		'style': 'width:100px'
	});

	var btn = E('button', {
		'class': 'cbi-button cbi-button-action',
		'style': 'margin-left:8px',
		'click': function() {
			var freq = parseInt(document.getElementById('oc-freq-input').value);
			if (isNaN(freq) || freq < 500 || freq > 1600) {
				ui.addNotification(null, E('p', {}, _('Frequency must be 500-1600 MHz')), 'error');
				return;
			}
			if (freq > 1400) {
				if (!confirm('WARNING: Frequencies above 1400 MHz may be unstable at stock voltage. Continue?')) {
					return;
				}
			}
			btn.disabled = true;
			btn.textContent = _('Applying...');
			callSetOverclock(freq).then(function(res) {
				btn.disabled = false;
				btn.textContent = _('Apply');
				if (res && res.error) {
					ui.addNotification(null, E('p', {}, _('Overclock failed: ') + res.error), 'error');
				} else if (res && res.result === 'ok') {
					ui.addNotification(null, E('p', {},
						_('CPU set to ') + res.actual_mhz + ' MHz (PCW=' + res.pcw + ', posdiv=' + res.posdiv + ')'), 'info');
				}
			}).catch(function(err) {
				btn.disabled = false;
				btn.textContent = _('Apply');
				ui.addNotification(null, E('p', {}, _('Overclock failed: ') + err.message), 'error');
			});
		}
	}, _('Apply'));

	return E('div', { 'style': 'display:flex;align-items:center;gap:8px;flex-wrap:wrap' }, [
		input,
		E('span', { 'style': 'color:#aaa' }, 'MHz'),
		btn,
		E('span', { 'style': 'color:#888;font-size:85%;margin-left:8px' },
			_('Direct PLL programming. Governor locked to performance. Stock max: 1200 MHz. Tested stable up to 1500 MHz.'))
	]);
}

function renderPpeRows(entries) {
	return entries.slice(0, 100).map(function(entry) {
		var stateClass = entry.state === 'BND' ? 'label-success' : '';
		var ethDisplay = entry.eth || '';
		if (ethDisplay === '00:00:00:00:00:00->00:00:00:00:00:00') {
			ethDisplay = '-';
		}
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, entry.index),
			E('td', { 'class': 'td' }, E('span', { 'class': stateClass }, entry.state)),
			E('td', { 'class': 'td' }, entry.type),
			E('td', { 'class': 'td' }, entry.orig || '-'),
			E('td', { 'class': 'td' }, entry.new_flow || '-'),
			E('td', { 'class': 'td' }, ethDisplay),
			E('td', { 'class': 'td' }, formatPackets(entry.packets || 0)),
			E('td', { 'class': 'td' }, formatBytes(entry.bytes || 0))
		]);
	});
}

return view.extend({
	load: function() {
		return Promise.all([
			callNpuStatus(),
			callPpeEntries()
		]);
	},

	render: function(data) {
		var status = data[0] || {};
		var ppeData = data[1] || {};
		var entries = Array.isArray(ppeData.entries) ? ppeData.entries : [];
		var memRegions = Array.isArray(status.memory_regions) ? status.memory_regions : [];
		var totalMemoryStr = calcTotalMemory(memRegions);

		var viewEl = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Airoha SoC Status')),

			// CPU Frequency Section
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('CPU Frequency')),
				E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td', 'width': '33%' }, E('strong', {}, _('Current Frequency'))),
						E('td', { 'class': 'td' },
							renderFreqBar(status.cpu_hw_freq, status.cpu_min_freq, status.cpu_max_freq, status.pll_freq_mhz))
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, E('strong', {}, _('Governor'))),
						E('td', { 'class': 'td' },
							renderGovernorSelect(status.cpu_avail_governors, status.cpu_governor))
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, E('strong', {}, _('Max Frequency'))),
						E('td', { 'class': 'td' },
							renderMaxFreqSelect(status.cpu_avail_freqs, status.cpu_max_freq))
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, E('strong', {}, _('Overclock'))),
						E('td', { 'class': 'td' }, renderOverclockControls())
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, E('strong', {}, _('CPU Cores'))),
						E('td', { 'class': 'td' }, (status.cpu_count || 0).toString())
					])
				])
			]),

			// NPU Information Section
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('NPU Information')),
				E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td', 'width': '33%' }, E('strong', {}, _('NPU Firmware Version'))),
						E('td', { 'class': 'td', 'id': 'npu-version' }, status.npu_version || _('Not available'))
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, E('strong', {}, _('NPU Status'))),
						E('td', { 'class': 'td', 'id': 'npu-status' }, status.npu_loaded ?
							E('span', { 'class': 'label-success' }, _('Active') + (status.npu_device ? ' (' + status.npu_device + ')' : '')) :
							E('span', { 'class': 'label-danger' }, _('Not Active')))
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, E('strong', {}, _('NPU Clock / Cores'))),
						E('td', { 'class': 'td', 'id': 'npu-clock' }, (status.npu_clock ? (status.npu_clock / 1000000).toFixed(0) + ' MHz' : 'N/A') + ' / ' + (status.npu_cores || 0) + ' cores')
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, E('strong', {}, _('Reserved Memory'))),
						E('td', { 'class': 'td', 'id': 'npu-memory' }, totalMemoryStr + ' (' + memRegions.length + ' regions)')
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, E('strong', {}, _('Offload Statistics'))),
						E('td', { 'class': 'td', 'id': 'npu-offload' }, formatPackets(status.offload_packets || 0) + ' packets / ' + formatBytes(status.offload_bytes || 0))
					])
				])
			]),

			// PPE Flow Offload Section
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('PPE Flow Offload Entries')),
				E('div', { 'class': 'cbi-section-descr', 'id': 'ppe-summary' },
					_('Total: ') + entries.length + ' | ' +
					_('Bound: ') + entries.filter(function(e) { return e.state === 'BND'; }).length + ' | ' +
					_('Unbound: ') + entries.filter(function(e) { return e.state === 'UNB'; }).length
				),
				E('table', { 'class': 'table', 'id': 'ppe-entries-table' }, [
					E('tr', { 'class': 'tr cbi-section-table-titles' }, [
						E('th', { 'class': 'th' }, _('Index')),
						E('th', { 'class': 'th' }, _('State')),
						E('th', { 'class': 'th' }, _('Type')),
						E('th', { 'class': 'th' }, _('Original Flow')),
						E('th', { 'class': 'th' }, _('New Flow')),
						E('th', { 'class': 'th' }, _('Ethernet')),
						E('th', { 'class': 'th' }, _('Packets')),
						E('th', { 'class': 'th' }, _('Bytes'))
					])
				].concat(renderPpeRows(entries)))
			])
		]);

		// Setup polling for live updates (5 second interval)
		poll.add(L.bind(function() {
			return Promise.all([
				callNpuStatus(),
				callPpeEntries()
			]).then(L.bind(function(data) {
				var status = data[0] || {};
				var ppeData = data[1] || {};
				var entries = Array.isArray(ppeData.entries) ? ppeData.entries : [];

				// Update CPU frequency bar
				updateFreqBar(status.cpu_hw_freq, status.cpu_min_freq, status.cpu_max_freq, status.pll_freq_mhz);

				// Update governor select
				var govSelect = document.getElementById('cpu-governor-select');
				if (govSelect && !govSelect.matches(':focus')) {
					govSelect.value = status.cpu_governor || '';
				}

				// Update max freq select
				var freqSelect = document.getElementById('cpu-maxfreq-select');
				if (freqSelect && !freqSelect.matches(':focus')) {
					freqSelect.value = (status.cpu_max_freq || 0).toString();
				}

				// Update NPU offload stats
				var offloadEl = document.getElementById('npu-offload');
				if (offloadEl) {
					offloadEl.textContent = formatPackets(status.offload_packets || 0) + ' packets / ' + formatBytes(status.offload_bytes || 0);
				}

				// Update NPU status
				var statusEl = document.getElementById('npu-status');
				if (statusEl) {
					statusEl.innerHTML = '';
					if (status.npu_loaded) {
						var span = document.createElement('span');
						span.className = 'label-success';
						span.textContent = _('Active') + (status.npu_device ? ' (' + status.npu_device + ')' : '');
						statusEl.appendChild(span);
					} else {
						var span = document.createElement('span');
						span.className = 'label-danger';
						span.textContent = _('Not Active');
						statusEl.appendChild(span);
					}
				}

				// Update PPE summary
				var summaryEl = document.getElementById('ppe-summary');
				if (summaryEl) {
					summaryEl.textContent = _('Total: ') + entries.length + ' | ' +
						_('Bound: ') + entries.filter(function(e) { return e.state === 'BND'; }).length + ' | ' +
						_('Unbound: ') + entries.filter(function(e) { return e.state === 'UNB'; }).length;
				}

				// Update PPE table
				var table = document.getElementById('ppe-entries-table');
				if (table) {
					while (table.rows.length > 1) {
						table.deleteRow(1);
					}
					var newRows = renderPpeRows(entries);
					newRows.forEach(function(row) {
						table.appendChild(row);
					});
				}
			}, this));
		}, this), 5);

		return viewEl;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
