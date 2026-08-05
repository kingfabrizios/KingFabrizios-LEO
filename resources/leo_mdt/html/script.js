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
      li.textContent = `#${inc.id} [${inc.type}] ${inc.detail || ''}`
      incidentList.prepend(li)
    }

    if (d.type === 'initIncidents') {
      const list = d.incidents || []
      incidentList.innerHTML = ''
      for (let i = 0; i < list.length; i++) {
        const inc = list[i]
        const li = document.createElement('li')
        li.textContent = `#${inc.incident_id or inc.id || inc.incident_id} [${inc.type}] ${inc.detail || ''}`
        incidentList.appendChild(li)
      }
    }
  })

})();
