const { useState, useEffect } = React

function App() {
  const [visible, setVisible] = useState(false)
  const [incidents, setIncidents] = useState([])
  const [selectedIncident, setSelectedIncident] = useState(null)
  const [units, setUnits] = useState([])

  useEffect(() => {
    window.addEventListener('message', handleMessage)
    return () => window.removeEventListener('message', handleMessage)
  }, [])

  function handleMessage(e) {
    const d = e.data
    if (!d) return
    if (d.type === 'toggle') setVisible(!!d.display)
    if (d.type === 'initIncidents') setIncidents(d.incidents || [])
    if (d.type === 'incident') setIncidents(prev => [d.incident, ...prev])
    if (d.type === 'unitUpdate') {
      const u = d.unit
      setUnits(prev => {
        const idx = prev.findIndex(x => (x.unit_id || x.unitId || x.unitId) === (u.unit_id || u.unitId))
        if (idx >= 0) {
          const copy = [...prev]
          copy[idx] = u
          return copy
        }
        return [u, ...prev]
      })
    }
    if (d.type === 'recentUnits') setUnits(d.units || [])
  }

  function close() {
    fetch('https://leo_mdt/close', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({}) })
  }

  function selectIncident(inc) {
    setSelectedIncident(inc)
    setUnits([])
    // request recent units for incident from the client-side script
    fetch('https://leo_mdt/requestUnits', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ incident_id: inc.incident_id || inc.id }) })
  }

  function assignUnit() {
    if (!selectedIncident) return
    // simple template for patrol unit; in future expose as UI form
    const template = {
      unit_type: 'patrol',
      pedModel: 's_m_y_cop_01',
      vehicleModel: 'police',
      spawnCoords: selectedIncident.coords || { x: 0.0, y: 0.0, z: 0.0 },
      behavior: 'drive_to_scene'
    }

    fetch('https://leo_mdt/assignUnit', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ incident_id: selectedIncident.incident_id || selectedIncident.id, template: template }) })
  }

  if (!visible) return null

  return (
    <div id="mdt">
      <header>
        <h1>MDT Prototype</h1>
        <div className="controls">
          <button onClick={assignUnit} className="primary">Assign Unit</button>
          <button onClick={close}>Close</button>
        </div>
      </header>
      <main>
        <section className="left">
          <h2>Active Incidents</h2>
          <ul>
            {incidents.map((inc) => (
              <li key={inc.incident_id || inc.id} className={selectedIncident && (selectedIncident.incident_id || selectedIncident.id) === (inc.incident_id || inc.id) ? 'selected' : ''} onClick={() => selectIncident(inc)}>
                <div className="inc-row">
                  <div className="inc-title">#{inc.incident_id || inc.id} [{inc.type}]</div>
                  <div className="inc-detail">{inc.detail || ''}</div>
                </div>
              </li>
            ))}
          </ul>
        </section>

        <section className="right">
          <h2>Units for Incident {selectedIncident ? `#${selectedIncident.incident_id || selectedIncident.id}` : ''}</h2>
          <div className="units">
            {units.length === 0 && <div className="empty">No units</div>}
            <ul>
              {units.map(u => (
                <li key={u.unit_id || (u.unitId)}>
                  <div><strong>Unit {u.unit_id}</strong> — {u.unit_type} — {u.status}</div>
                  <div>Host: {u.host || u.host}</div>
                  <div>Model: {u.ped_model || u.pedModel || ''} / {u.vehicle_model || u.vehicleModel || ''}</div>
                </li>
              ))}
            </ul>
          </div>
        </section>
      </main>
    </div>
  )
}

ReactDOM.render(<App />, document.getElementById('root'))
