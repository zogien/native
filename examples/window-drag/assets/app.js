let count=0;document.querySelector('#counter').onclick=event=>{event.currentTarget.textContent='Clicks: '+(++count)};
document.querySelector('#reload').onclick=()=>location.reload();
document.querySelector('#dynamic').onclick=()=>{const host=document.querySelector('#dynamic-host');if(host.firstChild){host.textContent='';return}const handle=document.createElement('div');handle.className='handle';handle.setAttribute('data-native-window-drag','');handle.textContent='Dynamically mounted drag surface';host.appendChild(handle)};
