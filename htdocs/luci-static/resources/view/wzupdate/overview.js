'use strict';
'require view';
'require rpc';
'require poll';
'require uci';
'require ui';

var callStatus = rpc.declare({ object: 'wzupdate', method: 'status' });
var callCheck = rpc.declare({ object: 'wzupdate', method: 'check' });
var callUpdate = rpc.declare({ object: 'wzupdate', method: 'update' });
var callCancel = rpc.declare({ object: 'wzupdate', method: 'cancel' });
var callReboot = rpc.declare({ object: 'wzupdate', method: 'reboot' });

var STAGES = [ _('检查更新'), _('下载固件'), _('完整性校验'), _('写入备份分区'), _('写入校验'), _('等待重启') ];

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(callStatus(), {}),
			L.resolveDefault(uci.load('wzupdate'), null)
		]);
	},

	render: function(data) {
		var st = data[0] || {};
		var self = this;

		this._refs = {};

		var href = L.resource('view/wzupdate/style.css');
		if (!document.querySelector('link[href="' + href + '"]'))
			document.head.appendChild(E('link', { rel: 'stylesheet', href: href }));

		var page = E('div', { id: 'wzupdate-page' }, [
			E('div', { 'class': 'wz-head' }, [
				E('div', {}, [
					E('h2', { 'class': 'wz-title' }, [ _('在线更新') ]),
					E('div', { 'class': 'wz-sub' }, [ _('安全升级：下载 → 校验 → 写入备份分区 → 手动重启生效，更新后可回退') ])
				]),
				E('div', { 'class': 'wz-actions' }, [
					this._refs.check = E('button', {
						'class': 'wz-btn',
						'click': function() {
							if (self._refs.check.dataset.mode === 'update')
								self._update();
							else
								self._check(false);
						}
					}, [ _('检查更新') ]),
					this._refs.reboot = E('button', {
						'class': 'wz-btn primary',
						'click': function() { self._reboot(); }
					}, [ _('重启并更新') ]),
					this._refs.cancel = E('button', {
						'class': 'wz-btn danger',
						'click': function() { self._cancel(); }
					}, [ _('撤回更新') ])
				])
			]),

			E('div', { 'class': 'wz-grid' }, [
				this._renderLocal(),
				this._renderRemote()
			]),

			this._renderFlow(),
			this._renderSettings()
		]);

		this._root = page;
		this._apply(st);

		// 进入页面自动检查一次（后端限制 1 分钟最多一次）
		var st0 = this._deriveState(st);
		if (!this._bootChecked) {
			this._bootChecked = true;
			if (st0 !== 'busy' && st0 !== 'pending' && st0 !== 'running')
				setTimeout(function() { self._check(true); }, 400);
		}

		poll.add(function() {
			return L.resolveDefault(callStatus(), null).then(function(s) {
				if (s)
					self._apply(s);
			});
		}, 3);

		return page;
	},

	_renderLocal: function() {
		var r = this._refs;
		return E('div', { 'class': 'wz-card' }, [
			E('div', { 'class': 'wz-card-head' }, [
				E('div', { 'class': 'wz-card-title' }, [ _('本地固件') ]),
				r.localBadge = E('span', { 'class': 'wz-badge ok' }, [ E('i', { 'class': 'wz-dot' }), _('当前系统运行中') ])
			]),
			r.localVer = E('div', { 'class': 'wz-ver' }),
			E('div', { style: 'margin-top:10px' }, [
				E('div', { 'class': 'wz-kv' }, [ E('span', {}, [ _('设备') ]), r.device = E('b') ]),
				E('div', { 'class': 'wz-kv' }, [ E('span', {}, [ _('固件类型') ]), r.target = E('b', { 'class': 'mono' }) ]),
				E('div', { 'class': 'wz-kv' }, [ E('span', {}, [ _('系统') ]), r.system = E('b') ]),
				E('div', { 'class': 'wz-kv' }, [ E('span', {}, [ _('回退备份') ]), r.rollback = E('b') ]),
				E('div', { 'class': 'wz-kv' }, [ E('span', {}, [ _('运行时长') ]), r.uptime = E('b') ])
			]),
			r.chips = E('div', { 'class': 'wz-chips' })
		]);
	},

	_renderRemote: function() {
		var r = this._refs;
		return E('div', { 'class': 'wz-card' }, [
			E('div', { 'class': 'wz-card-head' }, [
				E('div', { 'class': 'wz-card-title' }, [ _('在线版本') ]),
				r.remoteBadge = E('span', { 'class': 'wz-badge' }, [ E('i', { 'class': 'wz-dot' }), _('未检查') ])
			]),
			r.remoteVer = E('div', { 'class': 'wz-ver' }),
			E('div', { style: 'margin-top:10px' }, [
				E('div', { 'class': 'wz-kv' }, [ E('span', {}, [ _('发布标签') ]), r.remoteTag = E('b', { 'class': 'mono' }) ]),
				E('div', { 'class': 'wz-kv' }, [ E('span', {}, [ _('固件类型') ]), r.remoteName = E('b', { 'class': 'mono' }) ]),
				E('div', { 'class': 'wz-kv' }, [ E('span', {}, [ _('文件大小') ]), r.remoteSize = E('b') ]),
				E('div', { 'class': 'wz-kv' }, [ E('span', {}, [ _('上次检查') ]), r.checked = E('b') ])
			]),
			r.imageWarn = E('div', { 'class': 'wz-warnbar' }, [
				_('已选择无 WiFi 版：该固件不含无线驱动，更新后无线功能将不可用。')
			]),
			r.notes = E('ul', { 'class': 'wz-notes' })
		]);
	},

	_renderFlow: function() {
		var r = this._refs;
		var steps = [];
		for (var i = 0; i < STAGES.length; i++) {
			if (i > 0)
				steps.push(E('div', { 'class': 'wz-step-line' }));
			steps.push(E('div', { 'class': 'wz-step' }, [
				E('i', {}, [ String(i + 1) ]),
				E('span', {}, [ STAGES[i] ])
			]));
		}
		r.steps = steps;
		return E('div', { 'class': 'wz-card' }, [
			E('div', { 'class': 'wz-card-head', style: 'justify-content:flex-end' }, [
				r.flowBadge = E('span', { 'class': 'wz-badge' }, [ _('空闲') ])
			]),
			r.stepper = E('div', { 'class': 'wz-stepper' }, steps),
			r.progressFill = E('div', { 'class': 'wz-progress-fill' }),
			E('div', { 'class': 'wz-progress' }, [ r.progressFill ]),
			E('div', { 'class': 'wz-progress-meta' }, [
				E('span', {}, [ _('当前：'), r.stage = E('b', {}, [ _('空闲') ]) ]),
				r.progressExtra = E('span', {}, [ '—' ]),
				r.percent = E('b', {}, [ '0%' ])
			]),
			r.log = E('pre', { 'class': 'wz-log' })
		]);
	},

	_renderSettings: function() {
		var r = this._refs;
		var self = this;
		var s = 'wzupdate';

		r.enabled = E('input', {
			type: 'checkbox',
			checked: uci.get(s, 'settings', 'enabled') === '1',
			'change': function() { self._queueSave(); }
		});
		r.imageSel = E('select', {
			'class': 'wz-input',
			'change': function() { self._queueSave(); }
		}, [
			E('option', { value: 'auto' }, [ _('自动（推荐）') ]),
			E('option', { value: 'wifi' }, [ _('WiFi 版') ]),
			E('option', { value: 'nowifi' }, [ _('无 WiFi 版') ])
		]);
		r.imageSel.value = uci.get(s, 'settings', 'image') || 'auto';

		r.channelSel = E('select', {
			'class': 'wz-input',
			'change': function() { self._queueSave(); }
		}, [
			E('option', { value: 'auto' }, [ _('自动（直连失败走镜像）') ]),
			E('option', { value: 'github' }, [ _('仅 GitHub') ]),
			E('option', { value: 'mirror' }, [ _('仅镜像加速') ])
		]);
		r.channelSel.value = uci.get(s, 'settings', 'channel') || 'auto';

		return E('div', { 'class': 'wz-card' }, [
			E('div', { 'class': 'wz-section' }, [ _('更新设置') ]),
			E('div', { 'class': 'wz-field' }, [
				E('div', {}, [
					E('div', { 'class': 'wz-field-label' }, [ _('启用自动更新') ]),
					E('div', { 'class': 'wz-field-help' }, [ _('每 30 分钟检查一次；发现新版本自动下载、校验并写入备份分区，不会自动重启。修改后立即生效') ])
				]),
				E('div', { 'class': 'wz-field-control' }, [
					E('label', { 'class': 'wz-switch' }, [ r.enabled, E('span') ])
				])
			]),
			E('div', { 'class': 'wz-field' }, [
				E('div', {}, [
					E('div', { 'class': 'wz-field-label' }, [ _('更新固件类型') ]),
					E('div', { 'class': 'wz-field-help' }, [ _('默认与当前设备一致；无 WiFi 版不含无线驱动，仅在不需要无线功能时选择') ])
				]),
				E('div', { 'class': 'wz-field-control' }, [ r.imageSel ])
			]),
			E('div', { 'class': 'wz-field' }, [
				E('div', {}, [
					E('div', { 'class': 'wz-field-label' }, [ _('下载通道') ]),
					E('div', { 'class': 'wz-field-help' }, [ _('直连失败时自动尝试镜像地址；下载中断会从断点续传，写入前校验固件完整性') ])
				]),
				E('div', { 'class': 'wz-field-control' }, [ r.channelSel ])
			])
		]);
	},

	_apply: function(st) {
		var r = this._refs;
		if (this._root)
			this._root.classList.toggle('wz-dark', this._isDark());
		var local = st.local || {};
		var remote = st.remote || null;
		var prog = st.progress || {};
		var pending = st.pending || null;
		var settings = st.settings || {};

		var phase = prog.phase || 'idle';
		var percent = parseInt(prog.percent, 10) || 0;
		var state = this._deriveState(st);

		// 本地卡
		r.localVer.innerHTML = '';
		r.localVer.appendChild(document.createTextNode(local.version || _('未知')));
		r.localVer.appendChild(E('small', {}, [ _('编译时间') ]));
		r.device.textContent = local.device || '—';
		r.target.textContent = local.firmware === 'nowifi' ? _('无 WiFi 版') : _('WiFi 版');
		r.system.textContent = (local.release || 'iStoreOS') + ' / ' + _('内核') + ' ' + (local.kernel || '—');
		r.uptime.textContent = local.uptime || '—';
		r.rollback.textContent = pending
			? (pending.running ? _('保留上一版本，可回退') : _('保留当前版本，可撤回本次更新'))
			: _('更新后保留上一版本');
		r.localBadge.className = 'wz-badge ok';
		r.localBadge.innerHTML = '';
		r.localBadge.appendChild(E('i', { 'class': 'wz-dot' }));
		r.localBadge.appendChild(document.createTextNode(pending && pending.running ? _('已更新 · 运行中') : _('当前系统运行中')));

		r.chips.innerHTML = '';
		if (local.ab) {
			r.chips.appendChild(E('span', { 'class': 'wz-chip ok' }, [ _('支持安全回退') ]));
			r.chips.appendChild(E('span', { 'class': 'wz-chip' }, [ _('更新保留配置') ]));
			r.chips.appendChild(E('span', { 'class': 'wz-chip' }, [ _('写入前校验固件') ]));
		}
		else {
			r.chips.appendChild(E('span', { 'class': 'wz-chip err' }, [ _('分区不支持安全更新') ]));
			r.chips.appendChild(E('span', { 'class': 'wz-chip err' }, [ _('在线更新已禁用') ]));
		}

		// 在线卡
		var hasRemote = !!remote;
		r.remoteVer.innerHTML = '';
		r.remoteVer.appendChild(document.createTextNode(hasRemote && remote.version ? remote.version : (local.ab ? _('未检查') : _('不可用'))));
		r.remoteVer.appendChild(E('small', {}, [ _('最新编译版本') ]));
		r.remoteTag.textContent = hasRemote && remote.tag ? remote.tag : '—';
		r.remoteName.textContent = hasRemote && remote.name ? remote.name : (local.target || '—');
		r.remoteSize.textContent = hasRemote && remote.size > 0 ? this._size(remote.size) : '—';
		r.checked.textContent = hasRemote && remote.checked ? remote.checked : '—';
		r.imageWarn.style.display = (settings.image === 'nowifi') ? '' : 'none';

		r.notes.innerHTML = '';
		var notes = [];
		if (!local.ab) {
			notes.push(_('当前分区表没有可用的备份分区，无法安全写入新固件。'));
			if (local.abMissing)
				notes.push(_('未识别的分区：') + local.abMissing);
			if (local.labels)
				notes.push(_('已识别的分区：') + local.labels);
			notes.push(_('请先刷入支持双分区更新的分区镜像后再使用在线更新。'));
		}
		else if (hasRemote && remote.notes) {
			notes.push(remote.notes);
		}
		else if (hasRemote) {
			notes.push(_('在线版本信息已获取。'));
		}
		else {
			notes.push(_('尚未检查在线版本，点击「检查更新」开始。'));
		}
		notes.push(_('写入完成并校验通过后，需要手动重启才会切换到新版本。'));
		notes.forEach(function(n) { r.notes.appendChild(E('li', {}, [ n ])); });

		// 状态徽标
		var badge = { text: _('空闲'), kind: '' };
		if (state === 'unsupported')
			badge = { text: _('不支持在线更新'), kind: 'err' };
		else if (state === 'failed')
			badge = { text: _('更新失败'), kind: 'err' };
		else if (state === 'busy')
			badge = { text: _('正在更新'), kind: 'info' };
		else if (state === 'pending')
			badge = { text: _('已就绪，待重启'), kind: 'warn' };
		else if (state === 'running')
			badge = { text: _('已是最新'), kind: 'ok' };
		else if (state === 'available')
			badge = { text: _('发现新版本'), kind: 'info' };
		else if (phase === 'idle')
			badge = { text: hasRemote ? _('已是最新') : _('未检查'), kind: hasRemote ? 'ok' : '' };

		r.remoteBadge.className = 'wz-badge ' + badge.kind;
		r.remoteBadge.innerHTML = '';
		r.remoteBadge.appendChild(E('i', { 'class': 'wz-dot' }));
		r.remoteBadge.appendChild(document.createTextNode(badge.text));

		// 进度
		var stage = this._stageOf(state, phase, percent);
		var steps = r.stepper.querySelectorAll('.wz-step');
		for (var i = 0; i < steps.length; i++) {
			steps[i].classList.toggle('done', stage.index >= 0 && i < stage.index);
			steps[i].classList.toggle('active', i === stage.index);
		}
		r.progressFill.style.width = Math.max(0, Math.min(100, percent)) + '%';
		r.percent.textContent = Math.round(percent) + '%';
		r.stage.textContent = stage.index >= 0 ? STAGES[stage.index] : _('空闲');

		var flow = { text: _('空闲'), kind: '' };
		if (state === 'unsupported')
			flow = { text: _('不可用'), kind: 'err' };
		else if (state === 'failed')
			flow = { text: _('失败'), kind: 'err' };
		else if (state === 'pending')
			flow = { text: _('待重启'), kind: 'warn' };
		else if (state === 'running')
			flow = { text: _('已完成'), kind: 'ok' };
		else if (state === 'available')
			flow = { text: _('待开始'), kind: 'info' };
		else if (state === 'busy')
			flow = { text: STAGES[stage.index] + ' ' + Math.round(percent) + '%', kind: 'info' };
		r.flowBadge.className = 'wz-badge ' + flow.kind;
		r.flowBadge.textContent = flow.text;

		r.progressExtra.textContent = prog.message || '—';

		// 日志
		var logs = st.log || [];
		r.log.textContent = logs.length ? logs.join('\n') : _('暂无日志');
		r.log.scrollTop = r.log.scrollHeight;

		// 按钮
		var busy = (state === 'busy');
		var canUpdate = !!(remote && remote.newer && !pending && local.ab && state !== 'busy');
		r.check.textContent = canUpdate ? _('更新固件') : _('检查更新');
		r.check.dataset.mode = canUpdate ? 'update' : 'check';
		r.check.disabled = busy || state === 'pending';
		r.check.style.display = '';
		r.reboot.style.display = (state === 'pending') ? '' : 'none';
		r.cancel.style.display = (state === 'pending' || state === 'running') ? '' : 'none';
		r.cancel.textContent = (state === 'running') ? _('回退到上一版本') : _('撤回更新');

		this._hideThemeRefresh();
	},

	// Argon 在无保存按钮的页面会补一个「刷新」按钮，这里只隐藏本页所在的刷新按钮
	_hideThemeRefresh: function() {
		var root = document.getElementById('maincontent') || document.body;
		var nodes = root.querySelectorAll('button, a');
		for (var i = 0; i < nodes.length; i++) {
			var n = nodes[i];
			if (n.closest && n.closest('#wzupdate-page'))
				continue;
			var label = (n.textContent || '').trim() || n.getAttribute('title') || '';
			if (label === '刷新' || label === 'Refresh')
				n.style.display = 'none';
		}
	},

	_isDark: function() {
		var style = window.getComputedStyle(document.body);
		var parse = function(value) {
			var m = /rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+))?/.exec(value || '');
			if (!m)
				return null;
			return {
				lum: (0.299 * +m[1] + 0.587 * +m[2] + 0.114 * +m[3]) / 255,
				alpha: (m[4] === undefined) ? 1 : parseFloat(m[4])
			};
		};
		var bg = parse(style.backgroundColor);
		if (bg && bg.alpha > 0.1)
			return bg.lum < 0.5;
		var fg = parse(style.color);
		if (fg)
			return fg.lum > 0.6;
		return false;
	},

	_deriveState: function(st) {
		var local = st.local || {};
		var prog = st.progress || {};
		var phase = prog.phase || 'idle';
		if (!local.ab)
			return 'unsupported';
		if (phase === 'error')
			return 'failed';
		if (st.pending)
			return st.pending.running ? 'running' : 'pending';
		if (phase === 'checking' || phase === 'downloading' || phase === 'verifying' || phase === 'writing')
			return 'busy';
		if (st.remote && st.remote.newer)
			return 'available';
		return 'latest';
	},

	_stageOf: function(state, phase, percent) {
		if (state === 'unsupported')
			return { index: -1 };
		if (state === 'pending' || state === 'running')
			return { index: 5 };
		if (state === 'busy') {
			if (phase === 'checking')
				return { index: 0 };
			if (phase === 'downloading')
				return { index: 1 };
			if (phase === 'verifying')
				return { index: 2 };
			if (phase === 'writing')
				return { index: percent >= 88 ? 4 : 3 };
		}
		if (state === 'failed')
			return { index: phase === 'verifying' ? 2 : (phase === 'writing' ? 4 : -1) };
		return { index: -1 };
	},

	_size: function(bytes) {
		if (!bytes)
			return '—';
		if (bytes >= 1048576)
			return (bytes / 1048576).toFixed(1) + ' MB';
		if (bytes >= 1024)
			return (bytes / 1024).toFixed(0) + ' KB';
		return bytes + ' B';
	},

	_check: function(force) {
		var self = this;
		if (!force && Date.now() - (this._lastCheck || 0) < 60000) {
			ui.addNotification(null, E('p', {}, [ _('检查过于频繁，请 1 分钟后再试') ]), 'warning');
			return Promise.resolve();
		}
		this._lastCheck = Date.now();
		return callCheck().catch(function() {
			ui.addNotification(null, E('p', {}, [ _('检查更新失败，请查看日志') ]), 'error');
		}).then(function() {
			setTimeout(function() {
				L.resolveDefault(callStatus(), null).then(function(s) {
					if (s)
						self._apply(s);
				});
			}, 1000);
		});
	},

	_update: function() {
		var self = this;
		return callUpdate().catch(function() {
			ui.addNotification(null, E('p', {}, [ _('启动更新失败，请查看日志') ]), 'error');
		}).then(function() {
			setTimeout(function() {
				L.resolveDefault(callStatus(), null).then(function(s) {
					if (s)
						self._apply(s);
				});
			}, 1000);
		});
	},

	_reboot: function() {
		if (!window.confirm(_('确认重启并切换到新版本？重启期间网络会中断。')))
			return;
		return callReboot();
	},

	_cancel: function() {
		var msg = (this._refs.cancel.textContent.indexOf(_('回退')) === 0)
			? _('确认回退到上一版本并重启？')
			: _('确认撤回已写入的更新？');
		if (!window.confirm(msg))
			return;
		return callCancel();
	},

	_queueSave: function() {
		var self = this;
		if (this._saveTimer)
			clearTimeout(this._saveTimer);
		this._saveTimer = setTimeout(function() { self._persist(); }, 300);
	},

	_persist: function() {
		var self = this;
		var s = 'wzupdate';
		var want = this._refs.enabled.checked;
		uci.set(s, 'settings', 'enabled', want ? '1' : '0');
		uci.set(s, 'settings', 'auto', want ? '1' : '0');
		uci.set(s, 'settings', 'image', this._refs.imageSel.value);
		uci.set(s, 'settings', 'channel', this._refs.channelSel.value);
		return uci.save().then(function() {
			return uci.apply();
		}).then(function() {
			// 回读后端配置，确认确实写入成功
			return L.resolveDefault(callStatus(), null).then(function(st) {
				if (!st || !st.settings)
					throw new Error('status failed');
				if (!!st.settings.enabled !== want) {
					self._refs.enabled.checked = !!st.settings.enabled;
					throw new Error('verify failed');
				}
				ui.addNotification(null, E('p', {}, [ _('设置已保存并生效') ]), 'info');
			});
		}).catch(function() {
			ui.addNotification(null, E('p', {}, [ _('设置保存失败，请重试') ]), 'error');
		});
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
