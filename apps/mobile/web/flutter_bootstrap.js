{{flutter_js}}
{{flutter_build_config}}

function showPartyBoxLoadError() {
  const message = document.getElementById('partybox-loading-message');
  if (message) message.textContent = 'Не удалось загрузить игру. Проверьте интернет и попробуйте снова.';
  const retry = document.getElementById('partybox-retry');
  if (retry) retry.hidden = false;
}

window.addEventListener('error', () => {
  if (document.getElementById('partybox-loading')) showPartyBoxLoadError();
}, true);
window.addEventListener('unhandledrejection', () => {
  if (document.getElementById('partybox-loading')) showPartyBoxLoadError();
});
const loadTimeout = setTimeout(() => {
  if (document.getElementById('partybox-loading')) showPartyBoxLoadError();
}, 45000);

_flutter.loader.load({
  onEntrypointLoaded: async function (engineInitializer) {
    try {
      const appRunner = await engineInitializer.initializeEngine();
      await appRunner.runApp();
      clearTimeout(loadTimeout);
      document.getElementById('partybox-loading')?.remove();
    } catch (_) {
      showPartyBoxLoadError();
    }
  },
}).catch(showPartyBoxLoadError);
