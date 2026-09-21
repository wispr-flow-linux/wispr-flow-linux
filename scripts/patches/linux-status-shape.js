/*WISPR_LINUX_STATUS_SHAPE*/
/*
 * Publishes the status pill's painted bounding box in document.title as
 * "Status|x,y,w,h" (CSS px, window-relative) so the GNOME Window Bridge
 * extension can restrict the pill window's input area to it.
 *
 * Why: the status window is larger than the pill, and Wispr makes the empty
 * part click-through by polling pixel alpha and toggling setIgnoreMouseEvents,
 * which does nothing on native Wayland. Electron's setShape is a no-op there
 * too. Only the compositor can shape a Wayland surface's input, and it can't
 * see the DOM, so the renderer tells it. The title is the one channel a
 * Wayland client has to the compositor without a new protocol or preload/IPC.
 *
 * "Painted" mirrors Wispr's own hit test (any pixel with alpha > 0 captures
 * input, including its alpha 0.004 hit-area elements): visible, non-zero-size
 * elements with a background, image, shadow, border, text or pseudo-element
 * content, whose opacity chain is not ~0. Hidden variants are excluded.
 */
(function () {
	if (!/Linux/.test(navigator.userAgent)) return;
	var PAD = 6, pending = false;

	function clear(c) {
		return !c || c === 'transparent' ||
			/^rgba\(\s*\d+,\s*\d+,\s*\d+,\s*0\s*\)$/.test(c);
	}
	function paints(el, cs, r) {
		if (/^(svg|img|canvas|video|picture)$/i.test(el.tagName)) return true;
		if (!clear(cs.backgroundColor) || cs.backgroundImage !== 'none') return true;
		if (cs.boxShadow !== 'none') return true;
		if (parseFloat(cs.borderTopWidth) > 0 && !clear(cs.borderTopColor)) return true;
		for (var n = el.firstChild; n; n = n.nextSibling)
			if (n.nodeType === 3 && n.nodeValue.trim()) return true;
		if (r.width < 400 && r.height < 400) {
			var ps = ['::before', '::after'];
			for (var i = 0; i < 2; i++) {
				var p = getComputedStyle(el, ps[i]);
				if (p.content !== 'none' && p.content !== 'normal' &&
					(!clear(p.backgroundColor) || p.content.length > 2)) return true;
			}
		}
		return false;
	}
	function opacity(el) {
		var o = 1;
		for (var a = el; a && a !== document.documentElement; a = a.parentElement) {
			o *= parseFloat(getComputedStyle(a).opacity);
			if (o < 0.01) return 0;
		}
		return o;
	}
	function measure() {
		var x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
		var els = document.body.getElementsByTagName('*');
		for (var i = 0; i < els.length; i++) {
			var el = els[i], r = el.getBoundingClientRect();
			if (r.width <= 0 || r.height <= 0) continue;
			var cs = getComputedStyle(el);
			if (cs.visibility === 'hidden' || cs.display === 'none') continue;
			if (!paints(el, cs, r) || opacity(el) === 0) continue;
			x0 = Math.min(x0, r.left); y0 = Math.min(y0, r.top);
			x1 = Math.max(x1, r.right); y1 = Math.max(y1, r.bottom);
		}
		// The hovered chain: a transparent container that groups the pill with
		// its hover-only UI (globe button, tooltip) must stay inside the shape,
		// or the pointer could slip out through the gap between them and end
		// the hover. Skip the big layout wrappers (half the window or more).
		var hov = document.querySelectorAll(':hover');
		for (var j = 0; j < hov.length; j++) {
			var h = hov[j];
			if (h === document.documentElement || h === document.body) continue;
			var hr = h.getBoundingClientRect();
			if (hr.width <= 0 || hr.height <= 0) continue;
			if (hr.width * hr.height >= innerWidth * innerHeight * 0.5) continue;
			x0 = Math.min(x0, hr.left); y0 = Math.min(y0, hr.top);
			x1 = Math.max(x1, hr.right); y1 = Math.max(y1, hr.bottom);
		}
		if (x1 < x0) return; // nothing painted yet: keep the last shape
		x0 = Math.max(0, Math.floor(x0 - PAD)); y0 = Math.max(0, Math.floor(y0 - PAD));
		x1 = Math.min(innerWidth, Math.ceil(x1 + PAD)); y1 = Math.min(innerHeight, Math.ceil(y1 + PAD));
		var t = 'Status|' + [x0, y0, x1 - x0, y1 - y0].join(',');
		if (document.title !== t) document.title = t;
	}
	function running() {
		try {
			return document.getAnimations().some(function (a) {
				var t = a.effect && a.effect.getComputedTiming();
				return a.playState === 'running' && t && t.iterations !== Infinity;
			});
		} catch (e) { return false; }
	}
	function schedule() {
		if (pending) return;
		pending = true;
		requestAnimationFrame(function () {
			pending = false;
			measure();
			if (running()) schedule(); // follow finite transitions frame by frame
		});
	}

	new MutationObserver(schedule).observe(document.documentElement,
		{subtree: true, childList: true, attributes: true, characterData: true});
	['pointerover', 'pointerout', 'pointerenter', 'pointerleave', 'transitionrun',
		'transitionend', 'animationstart', 'animationend', 'load'
	].forEach(function (n) { addEventListener(n, schedule, true); });
	setInterval(schedule, 1000);
	schedule();
})();
