(() => {
  const app = document.getElementById('app')
  const closeBtn = document.getElementById('closeBtn')
  const incidentList = document.getElementById('incidentList')

  closeBtn.addEventListener('click', () => {
    fetch('https://leo_mdt/close', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({}) })
  })

  // Receive messages from the game
  window.addEventListener('message', (event) => {
    const d = event.data
    if (!d) return
    if (d.type === 'toggle') {
      if (d.display) app.classList.remove('hidden')
      else app.classList.add('hidden')
    }

    if (d.type === 'incident') {
      const inc = d.incident
      const li = document.createElement('li')
      li.textContent = `#${inc.id} [${inc.type}] ${inc.detail or ''}`
      incidentList.prepend(li)
    }
  })

  // Helper for Lua -> NUI to open with cached incidents
  window.addEventListener('message', (event) => {})

  // expose a global function the client script can call right after opening
  // client.lua will send NUI messages via SendNUIMessage, which appears as 'message' events
})();
