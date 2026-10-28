function encodeValsiForWeb(v) {
	return encodeURIComponent(v).replace(/'/g, 'h')
}

const AUDIO_LOAD_TIMEOUT_MS = 10000;

async function processNode(urli, Node, text, func) {
	return new Promise(resolve => {
		const controller = new AbortController();
		let sance;
		let settled = false;
		const timer = setTimeout(finish, AUDIO_LOAD_TIMEOUT_MS);

		function finish() {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			controller.abort();
			if (sance) {
				sance.removeEventListener('canplaythrough', ready);
				sance.removeEventListener('error', finish);
				sance.removeEventListener('abort', finish);
			}
			resolve();
		}

		function ready() {
			if (settled) return;
			try {
				func(Node, sance, text);
			} finally {
				finish();
			}
		}

		fetch(urli, { method: 'HEAD', signal: controller.signal }).then(res => {
			if (settled) return;
			if (res.status !== 200) {
				finish();
				return;
			}
			sance = new Audio();
			sance.id = 'sance_' + encodeValsiForWeb(text);
			sance.addEventListener('canplaythrough', ready);
			sance.addEventListener('error', finish);
			sance.addEventListener('abort', finish);
			sance.src = urli;
		}).catch(finish);
	});
}

function appendAudioControl(parent, sance, className) {
	const button = document.createElement('button');
	button.type = 'button';
	button.className = className;
	button.textContent = '▶';
	button.addEventListener('click', () => sance.play());
	parent.appendChild(sance);
	parent.appendChild(button);
}

function funcContentGloss(Node, sance, text) {
	appendAudioControl(Node.parentNode.parentNode, sance, 'tutci');
	return Node;
}

function funcExample(Node, sance, text) {
	appendAudioControl(Node.parentNode, sance, 'tutci tutci-mupli');
	return Node;
}

document.addEventListener("DOMContentLoaded", async function () {
	const loads = [];
	var words = document.querySelectorAll("em.glossterm");
	words = Array.from(words)
	for (var i = 0; i < words.length; i++) {
		var Node = words[i]
		var text = Node.innerText;
		loads.push(processNode(document.location.href.replace(/\/[^\/]+$/, '/') + "assets/media/vreji/" + encodeValsiForWeb(text) + ".mp3", Node, text, funcContentGloss));
	}

	var examples = Array.from(document.querySelectorAll(".example > .title > strong"));
	for (var i = 0; i < examples.length; i++) {
		var Node = examples[i]
		var text = Node.innerText.trim().replace(/ *Example (.*?)\. *$/, '$1');
		loads.push(processNode(document.location.href.replace(/\/[^\/]+$/, '/') + "assets/media/examples/" + text + ".ogg", Node, text, funcExample));
	}

	var terms = Array.from(document.querySelectorAll(".guibutton"));
	for (var i = 0; i < terms.length; i++) {
		var Node = terms[i]
		var slug = encodeValsiForWeb(Node.innerText);
		var li = "<button class='tutci' onclick=\"(function (){var s=new Audio('./assets/media/vreji/" + slug + ".mp3');s.play()})()\">▶</button>"
		Node.parentNode.insertAdjacentHTML('beforeend', li)
		Node.remove()
	}
	await Promise.all(loads);
});