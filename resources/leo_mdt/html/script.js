const { useState, useEffect, useRef } = React

function HostRow({ h, onOpen, threshold }) {
  const stale = h.heartbeatAge && h.heartbeatAge > threshold.warn
  const critical = h.queuedCount >= threshold.queued || (h.heartbeatAge && h.heartbeatAge > threshold.critical)
  return (
    <li className={stale ? 'stale' : (critical ? 'critical' : '')} onClick={() => onOpen(h)}>
      <div><strong>{h.name || ('Host ' + h.hostId)}</strong> {h.isDedicated ? '(ai_host)' : ''}</div>
      <div>Last HB: {h.lastHeartbeat ? new Date(h.lastHeartbeat * 1000).toLocaleString() : 'never'} ({h.heartbeatAge ? `${h.heartbeatAge}s ago` : 'N/A'})</div>
      <div>Active: {h.activeCount} | Queued: {h.queuedCount}</div>
    </li>
  )
}

function HostDetailModal({ detail, onClose, onSetMaintenance }) {
  if (!detail) return null
  return (
    <div className="modal">
      <div className="modal-content">
        <h3>Host {detail.hostId} — Detail</h3>
        <div>Position: {detail.position ? `${detail.position.x.toFixed(1)}, ${detail.position.y.toFixed(1)}` : 'N/A'}</div>
        <div>Heartbeat: {detail.heartbeat ? new Date(detail.heartbeat * 1000).toLocaleString() : 'N/A'}</div>
        <div>Active: {detail.activeCount} | Queued: {detail.queuedCount}</div>
        <h4>Units</h4>
        <ul>
          {detail.units.map(u => (
            <li key={u.unit_id}>Unit {u.unit_id} — {u.unit_type} — {u.status}</li>
          ))}
        </ul>
        <div className="modal-actions">
          <button onClick={() => onSetMaintenance(detail.hostId, true)}>Set Maintenance</button>
          <button onClick={() => onSetMaintenance(detail.hostId, false)}>Clear Maintenance</button>
          <button onClick={onClose}>Close</button>
        </div>
      </div>
    </div>
  )
}

function MapPanel({ hosts }) {
  const mapRef = useRef(null)
  const markersRef = useRef({})

  useEffect(() => {
    if (!mapRef.current) {
      // initialize simple CRS map for plotting game coordinates
      mapRef.current = L.map('map', { crs: L.CRS.Simple, minZoom: -5 }).setView([0,0], 0)
      L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { attribution: '' }).addTo(mapRef.current)
    }
  }, [])

  useEffect(() => {
    const map = mapRef.current
    if (!map) return
    // update markers
    Object.values(markersRef.current).forEach(m => map.removeLayer(m))
    markersRef.current = {}
    hosts.forEach(h => {
      if (!h.position) return
      const lat = h.position.y || 0
      const lng = h.position.x || 0
      const marker = L.marker([lat, lng]).addTo(map).bindPopup(`${h.name || ('Host ' + h.hostId)}<br/>Active:${h.activeCount} Queued:${h.queuedCount}`)
      markersRef.current[h.hostId] = marker
    })
  }, [hosts])

  return <div id="map" style={{ height: '180px', width: '100%', marginBottom: '8px' }}></div>
}

function App() {
  const [visible, setVisible] = useState(false)
  const [incidents, setIncidents] = useState([])
  const [selectedIncident, setSelectedIncident] = useState(null)
  const [units, setUnits] = useState([])
  const [hosts, setHosts] = useState([])
  const [detail, setDetail] = useState(null)
  const [threshold, setThreshold] = useState({ queued: 3, warn: 12, critical: 20 })

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
    if (d.type === 'hostsStatus') setHosts(d.hosts || [])
    if (d.type === 'hostDetail') setDetail(d.detail)
    if (d.type === 'hostsStatusUpdate') {
      fetch('https://leo_mdt/requestHosts', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({}) })
    }
  }

  function close() {
    fetch('https://leo_mdt/close', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({}) })
  }

  function selectIncident(inc) {
    setSelectedIncident(inc)
    setUnits([])
    fetch('https://leo_mdt/requestUnits', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ incident_id: inc.incident_id || inc.id }) })
    fetch('https://leo_mdt/requestHosts', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({}) })
  }

  function assignUnit() {
    if (!selectedIncident) return
    const template = {
      unit_type: 'patrol',
      pedModel: 's_m_y_cop_01',
      vehicleModel: 'police',
      spawnCoords: selectedIncident.coords || { x: 0.0, y: 0.0, z: 0.0 },
      behavior: 'drive_to_scene'
    }

    fetch('https://leo_mdt/assignUnit', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ incident_id: selectedIncident.incident_id || selectedIncident.id, template: template }) })
  }

  function refreshHosts() {
    fetch('https://leo_mdt/requestHosts', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({}) })
  }

  function openHostDetail(h) {
    fetch('https://leo_mdt/requestHostDetail', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ hostId: h.hostId }) })
  }

  function closeDetail() { setDetail(null) }

  function setMaintenance(hostId, enable) {
    fetch('https://leo_mdt/setHostMaintenance', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ hostId, enable }) })
    setDetail(null)
  }

  function setThresholds(newValues) {
    setThreshold(prev => ({ ...prev, ...newValues }))
  }

  if (!visible) return null

  const criticalCount = hosts.filter(h => (h.queuedCount >= threshold.queued) || (h.heartbeatAge && h.heartbeatAge > threshold.critical)).length

  return (
    <div id="mdt">
      <header>
        <h1>MDT Prototype</h1>
        <div className="controls">
          <button onClick={assignUnit} className="primary">Assign Unit</button>
          <button onClick={refreshHosts}>Refresh Hosts</button>
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
          <div className="hosts-header">
            <h2>Hosts</h2>
            <div className="alerts">Critical hosts: {criticalCount}</div>
          </div>

          <MapPanel hosts={hosts} />

          <div className="hosts">
            {hosts.length === 0 && <div className="empty">No hosts</div>}
            <ul>
              {hosts.map(h => (
                <HostRow key={h.hostId} h={h} onOpen={openHostDetail} threshold={threshold} />
              ))}
            </ul>
          </div>

          <div className="filters">
            <label>Queue threshold: <input type="number" value={threshold.queued} onChange={(e) => setThresholds({ queued: Number(e.target.value) })} /></label>
            <label>Warn HB (s): <input type="number" value={threshold.warn} onChange={(e) => setThresholds({ warn: Number(e.target.value) })} /></label>
            <label>Critical HB (s): <input type="number" value={threshold.critical} onChange={(e) => setThresholds({ critical: Number(e.target.value) })} /></label>
          </div>

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

      <HostDetailModal detail={detail} onClose={closeDetail} onSetMaintenance={setMaintenance} />
    </div>
  )
}

ReactDOM.render(<App />, document.getElementById('root'))
