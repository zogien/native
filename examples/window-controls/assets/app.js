// A page-drawn title bar: the buttons call the app's window commands, and
// the maximize button follows the window's own state, whoever changed it.
const label = document.body.dataset.window;
const stateText = document.querySelector('#state');
const maximizeButton = document.querySelector('#maximize');
const errorText = document.querySelector('#error');
let maximized = false;

function render(value) {
  maximized = value;
  stateText.textContent = 'Maximized: ' + value;
  maximizeButton.textContent = value ? 'Restore' : 'Maximize';
}

function invoke(name) {
  window.zero.commands.invoke(name).catch(error => {
    errorText.textContent = 'Error: ' + (error.code || error.message);
  });
}

document.querySelector('#minimize').onclick = () => invoke('controls.minimize');
maximizeButton.onclick = () => invoke(maximized ? 'controls.restore' : 'controls.maximize');
document.querySelector('#close').onclick = () => invoke('controls.close');
document.querySelector('#reload').onclick = () => location.reload();
let count = 0;
document.querySelector('#counter').onclick = event => {
  event.currentTarget.textContent = 'Clicks: ' + (++count);
};
const showPalette = document.querySelector('#show-palette');
if (showPalette) showPalette.onclick = () => invoke('controls.show-palette');

window.zero.on('window:state', detail => render(detail.maximized));
window.zero.on('fixture:error', detail => { errorText.textContent = 'Error: ' + detail.error; });
window.zero.on('fixture:closed', detail => {
  const closed = document.querySelector('#closed');
  if (closed) closed.textContent = 'Closed: ' + detail.label;
});

// The initial state comes from the window list, so a reload while
// maximized starts right.
window.zero.windows.list().then(windows => {
  const own = windows.find(window => window.label === label);
  render(own ? own.maximized : false);
}, error => {
  errorText.textContent = 'Error: ' + (error.code || error.message);
});
