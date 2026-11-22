'use strict';

(function() {
	if (window.__wzupdateNoticeInit)
		return;
	window.__wzupdateNoticeInit = true;

	var PAGE = 'admin/system/wzupdate';
	var DISMISS_KEY = 'wzupdate.notice.dismissed';
	var POLL = 60000;
	var CSS_ID = 'wzupdate-notice-style';
	var toast = null;
	var current_key = null;
	var dismissed_key = null;
	var timer = null;
	var stopped = false;

	var CSS = [
		'#wzupdate-notice{position:fixed;top:66px;right:18px;z-index:20000;width:336px;max-width:calc(100vw - 24px);box-sizing:border-box;display:flex;gap:12px;padding:14px 34px 14px 16px;border-radius:14px;background:rgba(255,255,255,.70);color:#1b1f24;border:1px solid rgba(16,24,40,.08);box-shadow:0 14px 36px rgba(16,24,40,.20);font:13px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;backdrop-filter:blur(12px);animation:wzupdate-notice-in .28s ease-out}',
		'#wzupdate-notice .wz-ico{flex:0 0 auto;width:34px;height:34px;border-radius:10px;display:flex;align-items:center;justify-content:center;background:#e7f8f0;color:#066344;font-size:18px;font-weight:700}',
		'#wzupdate-notice .wz-body{flex:1 1 auto;min-width:0}',
		'#wzupdate-notice .wz-title{font-size:14px;font-weight:600;line-height:1.5}',
		'#wzupdate-notice .wz-desc{margin:2px 0 0;color:#69707d;word-break:break-word}',
		'#wzupdate-notice .wz-actions{display:flex;gap:8px;margin-top:10px}',
		'#wzupdate-notice .wz-go{display:inline-flex;align-items:center;padding:5px 12px;border-radius:8px;background:#10a56f;color:#fff;text-decoration:none;font-weight:500}',
		'#wzupdate-notice .wz-go:hover{color:#fff;filter:brightness(1.06)}',
		'#wzupdate-notice .wz-close{position:absolute;top:5px;right:7px;border:0;background:transparent;color:inherit;opacity:.4;font-size:20px;line-height:1;padding:4px;cursor:pointer}',
		'#wzupdate-notice .wz-close:hover{opacity:.85}',
		'#wzupdate-notice .wz-close:focus-visible{outline:2px solid #10a56f;outline-offset:1px;border-radius:6px}',
		'html[data-argon-mode="dark"] #wzupdate-notice,html.dark #wzupdate-notice,body.dark #wzupdate-notice{background:rgba(37,37,38,.70);color:#e8e8ea;border-color:rgba(255,255,255,.10);box-shadow:0 14px 36px rgba(0,0,0,.45)}',
		'html[data-argon-mode="dark"] #wzupdate-notice .wz-ico,html.dark #wzupdate-notice .wz-ico,body.dark #wzupdate-notice .wz-ico{background:#16362a;color:#b9f5da}',
		'html[data-argon-mode="dark"] #wzupdate-notice .wz-desc,html.dark #wzupdate-notice .wz-desc,body.dark #wzupdate-notice .wz-desc{color:#a2a2a8}',
		'@keyframes wzupdate-notice-in{from{opacity:0;transform:translateY(-10px)}to{opacity:1;transform:none}}',
		'@media (max-width:640px){#wzupdate-notice{left:12px;right:12px;top:64px;width:auto}}'
	].join('');

	function inject_css() {
		if (document.getElementById(CSS_ID))
			return;
		var style = document.createElement('style');
		style.id = CSS_ID;
		style.textContent = CSS;
		document.head.appendChild(style);
	}

	function el(tag, cls) {
		var node = document.createElement(tag);
		if (cls)
			node.className = cls;
		return node;
	}

	function is_dismissed(key) {
		if (dismissed_key === key)
			return true;
		try {
			return window.localStorage.getItem(DISMISS_KEY) === key;
		}
		catch (e) {
			return false;
		}
	}

	function dismiss(key) {
		dismissed_key = key;
		try {
			window.localStorage.setItem(DISMISS_KEY, key);
		}
		catch (e) {}
	}

	function close() {
		if (toast && toast.parentNode)
			toast.parentNode.removeChild(toast);
		toast = null;
		current_key = null;
	}

	function show(key, title, desc, label) {
		if (toast && current_key === key)
			return;
		inject_css();
		close();

		var box = el('div');
		box.id = 'wzupdate-notice';
		box.setAttribute('role', 'status');

		var icon = el('div', 'wz-ico');
		icon.textContent = '\u2191';

		var body = el('div', 'wz-body');
		var head = el('div', 'wz-title');
		head.textContent = title;
		var text = el('p', 'wz-desc');
		text.textContent = desc;

		var actions = el('div', 'wz-actions');
		var go = el('a', 'wz-go');
		go.textContent = label || '去更新';
		go.href = L.url(PAGE);
		go.addEventListener('click', function() { dismiss(key); });
		actions.appendChild(go);

		body.appendChild(head);
		body.appendChild(text);
		body.appendChild(actions);

		var x = el('button', 'wz-close');
		x.type = 'button';
		x.title = '关闭';
		x.textContent = '\u00d7';
		x.addEventListener('click', function() {
			dismiss(key);
			close();
		});

		box.appendChild(icon);
		box.appendChild(body);
		box.appendChild(x);
		document.body.appendChild(box);
		toast = box;
		current_key = key;
	}

	function stop_poll() {
		stopped = true;
		if (timer) {
			clearInterval(timer);
			timer = null;
		}
	}

	function handle(st) {
		if (!st || typeof st !== 'object')
			return false;

		var pending = st.pending || null;
		var key = '';
		var title = '';
		var desc = '';
		var label = '';

		if (pending && st.settings && st.settings.auto) {
			key = 'pending:' + (pending.version || '');
			title = '新版固件已就绪';
			desc = '已写入备份分区，重启后切换到新版本。';
			label = '去重启';
		}

		if (!key)
			return false;

		if (is_dismissed(key)) {
			close();
			return true;
		}

		show(key, title, desc, label);
		return true;
	}

	function start() {
		if (timer || stopped)
			return;
		if (!window.L || !L.env || !L.env.sessionid)
			return;

		if (L.env.dispatchpath && L.env.dispatchpath.indexOf(PAGE) !== -1)
			return;

		L.require('rpc').then(function(rpc) {
			var call = rpc.declare({ object: 'wzupdate', method: 'status' });
			var tick = function() {
				if (stopped)
					return;
				call().then(function(st) {
					if (handle(st))
						stop_poll();
				}).catch(function() {});
			};
			tick();
			timer = setInterval(function() {
				if (!document.hidden)
					tick();
			}, POLL);
			document.addEventListener('visibilitychange', function() {
				if (!document.hidden)
					tick();
			});
		}).catch(function() {});
	}

	document.addEventListener('luci-loaded', start);
	if (document.readyState === 'loading')
		document.addEventListener('DOMContentLoaded', function() { setTimeout(start, 0); });
	else
		setTimeout(start, 0);
})();
