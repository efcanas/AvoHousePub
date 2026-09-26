(function(){
'use strict';

const SUPABASE_URL='https://tjarildqqxtjmafpiyuz.supabase.co';
const SUPABASE_PUBLISHABLE_KEY='sb_publishable_Clp6KIiLE-gKHGu3Lp8E2A_DxYhFBdT';
const HOME_PATH='/index.html';
const AHTV_PATH='/ahtv/index.html';
const LOGIN_PATH='/cuenta/ingresar.html';
const REGISTER_PATH='/cuenta/registro.html';

function isAhtvPage(){return location.pathname===AHTV_PATH||location.pathname==='/ahtv/';}
function escapeHtml(value){return String(value??'').replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];});}

function installStyle(){
  if(document.getElementById('ah-global-style'))return;
  const css=document.createElement('style');
  css.id='ah-global-style';
  css.textContent='.ah-global-header{position:fixed;top:16px;right:16px;z-index:10000;display:flex;align-items:center;gap:8px;font-family:Arial,sans-serif}'+
  '.ah-global-link,.ah-global-user{display:inline-flex;align-items:center;justify-content:center;min-height:38px;padding:0 13px;border-radius:20px;border:1px solid rgba(255,255,255,.42);background:rgba(0,0,0,.42);backdrop-filter:blur(8px);color:#fff;text-decoration:none;font-size:12px;letter-spacing:1.2px;white-space:nowrap;box-shadow:0 8px 24px rgba(0,0,0,.18)}'+
  '.ah-global-link:hover,.ah-global-user:hover,.ah-global-user.open{background:rgba(255,255,255,.12);border-color:rgba(255,255,255,.72)}'+
  '.ah-global-user{cursor:pointer;font-weight:700;letter-spacing:.7px;gap:6px}'+
  '.ah-global-arrow{font-size:10px;opacity:.72;transition:transform .18s ease}'+
  '.ah-global-user.open .ah-global-arrow{transform:rotate(180deg)}'+
  '.ah-global-dropdown{position:absolute;top:46px;right:0;min-width:170px;padding:7px;border:1px solid rgba(255,255,255,.2);border-radius:15px;background:rgba(13,13,13,.94);backdrop-filter:blur(14px);box-shadow:0 18px 45px rgba(0,0,0,.35);display:none}'+
  '.ah-global-dropdown.show{display:block}'+
  '.ah-global-dropdown a,.ah-global-dropdown button{width:100%;display:block;text-align:left;padding:10px 11px;border-radius:10px;border:0;background:transparent;color:#fff;text-decoration:none;font:inherit;font-size:13px;cursor:pointer}'+
  '.ah-global-dropdown a:hover,.ah-global-dropdown button:hover{background:rgba(255,255,255,.08)}'+
  '.ah-global-dropdown button{border-top:1px solid rgba(255,255,255,.1);border-radius:0 0 10px 10px}'+
  '.ah-music-modal{position:fixed;inset:0;z-index:10001;display:flex;align-items:center;justify-content:center;padding:22px;background:rgba(0,0,0,.72);backdrop-filter:blur(5px)}'+
  '.ah-music-modal[hidden]{display:none}'+
  '.ah-music-card{width:min(430px,100%);padding:27px 23px;border-radius:20px;background:rgba(18,18,18,.97);border:1px solid rgba(255,255,255,.18);box-shadow:0 20px 60px rgba(0,0,0,.45);text-align:center}'+
  '.ah-music-card h2{margin:0 0 12px;font-size:21px;letter-spacing:1px}'+
  '.ah-music-card p{margin:0;color:#cfcfcf;line-height:1.55;font-size:14px}'+
  '.ah-music-actions{display:flex;gap:9px;margin-top:20px}'+
  '.ah-music-actions a{flex:1;text-decoration:none;padding:12px 10px;border-radius:11px;border:1px solid rgba(255,255,255,.38);color:#fff;font-size:13px;font-weight:700}'+
  '.ah-music-actions a.primary{background:#fff;color:#111;border-color:#fff}'+
  '.ah-music-close{margin-top:13px;background:transparent;color:#aaa;border:0;font:inherit;font-size:12px;cursor:pointer}'+
  '@media(max-width:520px){.ah-global-header{top:10px;right:10px;gap:6px}.ah-global-link,.ah-global-user{min-height:34px;padding:0 10px;font-size:10px;letter-spacing:.9px}.ah-music-actions{flex-direction:column}}';
  document.head.appendChild(css);
}

function createMusicModal(){
  let modal=document.getElementById('ahMusicModal');
  if(modal)return modal;
  modal=document.createElement('div');
  modal.id='ahMusicModal';
  modal.className='ah-music-modal';
  modal.hidden=true;
  modal.innerHTML='<div class="ah-music-card" role="dialog" aria-modal="true" aria-labelledby="ahMusicTitle">'+
    '<h2 id="ahMusicTitle">Solicitar música</h2>'+
    '<p>Solicitar música es una función exclusiva para usuarios de AvoHouse. Ingresa a tu cuenta o regístrate para poder enviar una solicitud.</p>'+
    '<div class="ah-music-actions"><a class="primary" id="ahMusicLogin" href="'+LOGIN_PATH+'?returnTo='+encodeURIComponent(AHTV_PATH)+'">Iniciar sesión</a><a id="ahMusicRegister" href="'+REGISTER_PATH+'">Registrarme</a></div>'+
    '<button class="ah-music-close" id="ahMusicClose" type="button">Cerrar</button></div>';
  document.body.appendChild(modal);
  function close(){modal.hidden=true;}
  modal.addEventListener('click',function(e){if(e.target===modal)close();});
  document.getElementById('ahMusicClose').addEventListener('click',close);
  document.addEventListener('keydown',function(e){if(e.key==='Escape'&&!modal.hidden)close();});
  return modal;
}
function showMusicModal(){createMusicModal().hidden=false;}

function injectHeader(session,isAdmin,username,pointsBalance){
  const old=document.getElementById('ahGlobalHeader');
  if(old)old.remove();
  const header=document.createElement('nav');
  header.id='ahGlobalHeader';
  header.className='ah-global-header';

  const primary=document.createElement('a');
  primary.className='ah-global-link';
  primary.href=isAhtvPage()?HOME_PATH:AHTV_PATH;
  primary.textContent=isAhtvPage()?'MENÚ':'AHtv';
  header.appendChild(primary);

  if(!session&&!isAdmin){
    const login=document.createElement('a');
    login.className='ah-global-link';
    login.href=LOGIN_PATH;
    login.textContent='INGRESAR / REGISTRARSE';
    header.appendChild(login);
  }else if(session&&!isAdmin){
    const wrap=document.createElement('div');
    wrap.style.position='relative';
    const button=document.createElement('button');
    button.type='button';
    button.className='ah-global-user';
    button.innerHTML=escapeHtml(username||'Usuario')+' <span class="ah-global-arrow">▾</span>';

    const dropdown=document.createElement('div');
    dropdown.className='ah-global-dropdown';
    const pointsText=Number.isInteger(pointsBalance)?pointsBalance+' AP':'— AP';
    dropdown.innerHTML='<a class="ah-global-points" href="/cuenta/mi-cuenta.html#puntos">'+pointsText+'</a><button type="button" id="ahLogoutButton">Cerrar sesión</button>';

    button.addEventListener('click',function(e){e.stopPropagation();const open=!dropdown.classList.contains('show');dropdown.classList.toggle('show',open);button.classList.toggle('open',open);});
    dropdown.addEventListener('click',function(e){e.stopPropagation();});
    document.addEventListener('click',function(){dropdown.classList.remove('show');button.classList.remove('open');});
    dropdown.querySelector('#ahLogoutButton').addEventListener('click',async function(){this.disabled=true;await window.ahSupabase.auth.signOut();location.href=HOME_PATH;});
    wrap.append(button,dropdown);
    header.appendChild(wrap);
  }
  document.body.appendChild(header);
}

async function init(){
  installStyle();
  createMusicModal();
  if(!window.supabase?.createClient)return;

  window.ahSupabase=window.supabase.createClient(SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});

  let session=null;
  try{const result=await window.ahSupabase.auth.getSession();session=result?.data?.session||null;}catch(e){console.error(e);}

  let isAdmin=false;
  let profile=null;
  let pointsBalance=null;

  if(session?.user){
    try{
      const adminResult=await window.ahSupabase.from('admin_users').select('user_id').eq('user_id',session.user.id).maybeSingle();
      isAdmin=!adminResult.error&&!!adminResult.data;
    }catch(e){console.error(e);}

    if(!isAdmin){
      try{
        const profileResult=await window.ahSupabase.from('profiles').select('username,full_name').eq('id',session.user.id).maybeSingle();
        profile=profileResult.data||null;
      }catch(e){console.error(e);}
      try{
        const pointsResult=await window.ahSupabase.from('avopuntos_accounts').select('balance').eq('profile_id',session.user.id).maybeSingle();
        if(!pointsResult.error && Number.isInteger(pointsResult.data?.balance)) pointsBalance=pointsResult.data.balance;
      }catch(e){console.error(e);}
    }
  }

  window.AHAuthState={session:session,isAdmin:isAdmin,profile:profile,pointsBalance:pointsBalance};
  injectHeader(session,isAdmin,profile?.username,pointsBalance);

  if(session?.user && !isAdmin){
    const pointsChannel=window.ahSupabase
      .channel('ah-avopuntos-'+session.user.id)
      .on('postgres_changes',{
        event:'UPDATE',
        schema:'public',
        table:'avopuntos_accounts',
        filter:'profile_id=eq.'+session.user.id
      },function(payload){
        const next=Number(payload?.new?.balance);
        if(!Number.isInteger(next))return;
        window.AHAuthState.pointsBalance=next;
        const pointsLink=document.querySelector('.ah-global-points');
        if(pointsLink)pointsLink.textContent=next+' AP';
      })
      .subscribe();
  }

  if(isAhtvPage()&&isAdmin){location.replace('/ahtv/admin/index.html');return;}
  if(isAhtvPage()&&!session){location.replace('/index.html?music=1');return;}

  document.addEventListener('click',function(e){
    const link=e.target.closest('a');
    if(!link)return;
    const href=link.getAttribute('href')||'';
    let target;
    try{target=new URL(href,location.href);}catch(_){return;}
    if(target.origin!==location.origin||target.pathname!==AHTV_PATH)return;
    if(isAdmin){e.preventDefault();location.href='/ahtv/admin/index.html';return;}
    if(!session){e.preventDefault();showMusicModal();}
  });

  if(location.pathname===HOME_PATH||location.pathname==='/'){
    if(session&&!isAdmin){
      document.querySelectorAll('a[href="ahtv/index.html"],a[href="/ahtv/index.html"]').forEach(function(link){
        if(link.closest('#ahGlobalHeader'))return;
        link.style.display='none';
      });
    }
    if(new URLSearchParams(location.search).get('music')==='1'&&!session)showMusicModal();
  }
}

window.addEventListener('DOMContentLoaded',init);
})();