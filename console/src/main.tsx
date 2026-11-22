import { useCallback, useEffect, useMemo, useState, type FormEvent, type ReactNode } from 'react'
import { Activity, Bot, CheckCircle2, CircleAlert, ClipboardList, FolderPlus, LogOut, Plus, RefreshCw, ShieldCheck, Users, X } from 'lucide-react'
import { supabase, supabaseConfigured } from './supabase'
import './style.css'

type Project = { id: string; name: string; github_repo?: string | null; description?: string | null }
type Worker = { id: string; worker_key: string; display_name: string; status: string; last_seen_at?: string | null }
type Task = { id: string; title: string; task_type: string; status: string; priority: number; requires_review: boolean; created_at: string; assigned_worker_id?: string | null }
type RpcResult<T> = { success?: boolean; data?: T; error?: string }
const PROJECT_STORAGE_KEY = 'recursive-engine.owner-project'

function messageOf(error: unknown) {
  if (error && typeof error === 'object' && 'message' in error) return String(error.message)
  return String(error)
}
function shortId(value: string) { return value.slice(0, 8) }
function statusLabel(value: string) {
  const map: Record<string, string> = { pending: '待领取', running: '执行中', submitted: '待审核', accepted: '已通过', rejected: '已拒绝', failed: '失败', cancelled: '已取消', active: '活跃', inactive: '停用' }
  return map[value] ?? value
}

export default function App() {
  const [session, setSession] = useState<any>(null)
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [authBusy, setAuthBusy] = useState(false)
  const [project, setProject] = useState<Project | null>(null)
  const [projectId, setProjectId] = useState(localStorage.getItem(PROJECT_STORAGE_KEY) ?? '')
  const [workers, setWorkers] = useState<Worker[]>([])
  const [tasks, setTasks] = useState<Task[]>([])
  const [selectedTask, setSelectedTask] = useState<any>(null)
  const [loading, setLoading] = useState(false)
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState<{ kind: 'ok' | 'error'; text: string } | null>(null)
  const [projectForm, setProjectForm] = useState({ name: '', github_repo: '', description: '' })
  const [workerForm, setWorkerForm] = useState({ worker_key: '', display_name: '', description: '' })
  const [taskForm, setTaskForm] = useState({ title: '', description: '', requirements: '', priority: '100', requires_review: true })
  const [showProject, setShowProject] = useState(false)
  const [showWorker, setShowWorker] = useState(false)
  const [showTask, setShowTask] = useState(false)

  const notify = (kind: 'ok' | 'error', text: string) => setNotice({ kind, text })
  const rpc = useCallback(async <T,>(name: string, args: Record<string, unknown>) => {
    if (!supabase) throw new Error('尚未配置 Supabase 环境变量')
    const { data, error } = await supabase.rpc(name, args)
    if (error) throw error
    const result = data as RpcResult<T>
    if (result?.success === false) throw new Error(result.error ?? name + ' failed')
    return result?.data as T
  }, [])

  useEffect(() => {
    if (!supabase) return
    supabase.auth.getSession().then(({ data }) => setSession(data.session))
    const { data: listener } = supabase.auth.onAuthStateChange((_event, next) => setSession(next))
    return () => listener.subscription.unsubscribe()
  }, [])

  const refresh = useCallback(async (id = projectId) => {
    if (!id || !supabase) return
    setLoading(true)
    try {
      const [p, w, t] = await Promise.all([
        rpc<Project>('get_project', { p_project_id: id }),
        rpc<Worker[]>('list_workers', { p_project_id: id }),
        rpc<Task[]>('list_tasks', { p_project_id: id, p_status: null, p_worker_id: null, p_limit: 100, p_cursor: null }),
      ])
      setProject(p)
      setWorkers(Array.isArray(w) ? w : [])
      setTasks(Array.isArray(t) ? t : [])
      setSelectedTask(null)
    } catch (error) {
      setProject(null)
      notify('error', messageOf(error))
    } finally { setLoading(false) }
  }, [projectId, rpc])

  useEffect(() => { if (session && projectId) void refresh(projectId) }, [session, projectId, refresh])

  const counts = useMemo(() => ({
    total: tasks.length,
    active: tasks.filter(t => t.status === 'running').length,
    review: tasks.filter(t => t.status === 'submitted').length,
    done: tasks.filter(t => t.status === 'accepted').length,
  }), [tasks])

  async function signIn(event: FormEvent) {
    event.preventDefault()
    if (!supabase) return
    setAuthBusy(true)
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    setAuthBusy(false)
    if (error) notify('error', error.message)
  }

  async function signOut() {
    await supabase?.auth.signOut()
    setSession(null)
    setProject(null)
    setWorkers([])
    setTasks([])
  }

  async function createProject(event: FormEvent) {
    event.preventDefault()
    setBusy(true)
    try {
      const created = await rpc<Project>('register_project', {
        p_name: projectForm.name.trim(),
        p_description: projectForm.description.trim() || null,
        p_github_repo: projectForm.github_repo.trim() || null,
        p_config: { console: 'owner-v1' },
        p_idempotency_key: crypto.randomUUID(),
      })
      if (!created?.id) throw new Error('register_project 未返回项目 ID')
      setProjectId(created.id)
      localStorage.setItem(PROJECT_STORAGE_KEY, created.id)
      try {
        await rpc<Worker>('register_worker', { p_project_id: created.id, p_worker_key: 'coordinator', p_display_name: 'Coordinator', p_description: 'Owner console coordinator identity' })
      } catch { /* Project creation remains valid if Coordinator registration is retried below. */ }
      setShowProject(false)
      setProjectForm({ name: '', github_repo: '', description: '' })
      notify('ok', '项目已创建')
      await refresh(created.id)
    } catch (error) { notify('error', messageOf(error)) }
    finally { setBusy(false) }
  }

  async function createWorker(event: FormEvent) {
    event.preventDefault()
    if (!projectId) return
    setBusy(true)
    try {
      await rpc<Worker>('register_worker', { p_project_id: projectId, p_worker_key: workerForm.worker_key.trim(), p_display_name: workerForm.display_name.trim(), p_description: workerForm.description.trim() || null })
      setShowWorker(false)
      setWorkerForm({ worker_key: '', display_name: '', description: '' })
      notify('ok', 'Worker 已注册')
      await refresh()
    } catch (error) { notify('error', messageOf(error)) }
    finally { setBusy(false) }
  }

  async function createTask(event: FormEvent) {
    event.preventDefault()
    if (!projectId) return
    const coordinator = workers.find(w => w.worker_key === 'coordinator')
    const creator = coordinator ?? workers[0]
    if (!creator) { notify('error', '请先注册至少一个 Worker'); return }
    let requirements: unknown = {}
    try { requirements = taskForm.requirements.trim() ? JSON.parse(taskForm.requirements) : {} }
    catch { notify('error', 'Requirements 必须是合法 JSON'); return }
    setBusy(true)
    try {
      await rpc<Task>('create_task', {
        p_project_id: projectId,
        p_worker_id: creator.id,
        p_task_type: 'implementation',
        p_title: taskForm.title.trim(),
        p_description: taskForm.description.trim(),
        p_requirements: requirements,
        p_priority: Number(taskForm.priority) || 100,
        p_requires_review: taskForm.requires_review,
        p_parent_task_id: null,
        p_fixes_task_id: null,
        p_idempotency_key: crypto.randomUUID(),
      })
      setShowTask(false)
      setTaskForm({ title: '', description: '', requirements: '', worker_id: '', priority: '100', requires_review: true })
      notify('ok', '任务已发布到任务池')
      await refresh()
    } catch (error) { notify('error', messageOf(error)) }
    finally { setBusy(false) }
  }

  async function inspectTask(id: string) {
    setBusy(true)
    try { setSelectedTask(await rpc<any>('get_task', { p_task_id: id })) }
    catch (error) { notify('error', messageOf(error)) }
    finally { setBusy(false) }
  }

  if (!supabaseConfigured) return <main className="setup"><div className="setup-card"><div className="brand-mark"><Activity /></div><h1>Owner Console</h1><p>尚未配置 Supabase 连接。</p><ol><li>复制 <code>console/.env.example</code> 为 <code>console/.env.local</code></li><li>填入项目 URL 和 Publishable Key</li><li>重新启动开发服务器</li></ol><p className="muted">禁止使用 service_role / secret key。</p></div></main>

  if (!session) return <main className="login-shell"><form className="login-card" onSubmit={signIn}><div className="brand-mark"><Activity /></div><p className="eyebrow">RECURSIVE AI ENGINEERING</p><h1>Owner 控制台</h1><p className="muted">使用已创建的 Supabase Owner 账户登录。</p><label>邮箱<input type="email" autoComplete="username" value={email} onChange={e => setEmail(e.target.value)} required /></label><label>密码<input type="password" autoComplete="current-password" value={password} onChange={e => setPassword(e.target.value)} required /></label><button className="primary full" disabled={authBusy}>{authBusy ? '登录中…' : '登录'}</button>{notice && <p className="error-text">{notice.text}</p>}</form></main>

  return <div className="app-shell">
    <aside className="sidebar">
      <div className="brand"><div className="brand-mark"><Activity /></div><div><strong>Recursive Engine</strong><small>OWNER CONSOLE · MVP 1.1</small></div></div>
      <div className="side-caption">WORKSPACE</div>
      <button className="side-link active"><ClipboardList size={17}/> 项目工作台</button>
      <div className="side-bottom"><div className="user-chip"><div className="avatar">{String(session.user.email ?? 'O').slice(0,1).toUpperCase()}</div><div><strong>Owner</strong><small>{session.user.email}</small></div></div><button className="side-link" onClick={signOut}><LogOut size={16}/> 退出登录</button></div>
    </aside>
    <main className="main">
      <header className="topbar"><div><span className="crumb">工作区 / </span><strong>{project?.name ?? '项目'}</strong></div><div className="top-actions"><span className="secure"><ShieldCheck size={15}/> Authenticated</span><button className="icon-button" onClick={() => void refresh()} title="刷新" disabled={loading}><RefreshCw size={17}/></button></div></header>
      {notice && <div className={`notice ${notice.kind}`}>{notice.kind === 'ok' ? <CheckCircle2 size={17}/> : <CircleAlert size={17}/>}<span>{notice.text}</span><button onClick={() => setNotice(null)}><X size={15}/></button></div>}
      {!projectId || !project ? <section className="welcome"><div className="welcome-icon"><FolderPlus size={26}/></div><p className="eyebrow">GET STARTED</p><h1>创建你的第一个项目</h1><p className="muted">项目创建后，可注册 Worker、发布任务并追踪执行和审核状态。</p><button className="primary" onClick={() => setShowProject(true)}><Plus size={17}/> 创建项目</button><div className="project-switch"><label>已有项目 ID<input value={projectId} onChange={e => setProjectId(e.target.value.trim())} placeholder="粘贴项目 UUID" /></label><button className="secondary" onClick={() => { localStorage.setItem(PROJECT_STORAGE_KEY, projectId); void refresh(projectId) }}>载入项目</button></div></section> : <>
        <section className="page-heading"><div><p className="eyebrow">PROJECT OVERVIEW</p><h1>{project.name}</h1><p className="muted">{project.github_repo || '未绑定 GitHub 仓库'} <span className="dot-sep">·</span> <code>{shortId(project.id)}</code></p></div><div className="heading-actions"><button className="secondary" onClick={() => setShowWorker(true)}><Users size={16}/> 注册 Worker</button><button className="primary" onClick={() => setShowTask(true)}><Plus size={16}/> 发布任务</button></div></section>
        <section className="stats-grid"><Stat label="任务总数" value={counts.total} icon={<ClipboardList/>}/><Stat label="执行中" value={counts.active} icon={<Activity/>}/><Stat label="待审核" value={counts.review} icon={<ShieldCheck/>}/><Stat label="已通过" value={counts.done} icon={<CheckCircle2/>}/></section>
        <section className="content-grid"><div className="panel task-panel"><div className="panel-head"><div><h2>任务队列</h2><p>最新 100 条任务记录</p></div><button className="text-button" onClick={() => void refresh()}>刷新</button></div>{tasks.length === 0 ? <Empty text="暂无任务。发布第一个任务开始协作。" /> : <div className="task-list">{tasks.map(task => <button className="task-row" key={task.id} onClick={() => void inspectTask(task.id)}><div className="task-icon"><ClipboardList size={17}/></div><div className="task-info"><strong>{task.title}</strong><small>{task.task_type} · {shortId(task.id)} · {new Date(task.created_at).toLocaleString()}</small></div><Status value={task.status}/></button>)}</div>}</div>
          <div className="panel worker-panel"><div className="panel-head"><div><h2>Worker 池</h2><p>{workers.length} 个逻辑 Worker</p></div><button className="icon-button" onClick={() => setShowWorker(true)}><Plus size={17}/></button></div>{workers.length === 0 ? <Empty text="尚未注册 Worker。" /> : workers.map(worker => <div className="worker-row" key={worker.id}><div className="worker-avatar"><Bot size={17}/></div><div className="worker-info"><strong>{worker.display_name}</strong><small>{worker.worker_key}</small></div><Status value={worker.status}/></div>)}</div></section>
        {selectedTask && <section className="panel detail-panel"><div className="panel-head"><div><h2>任务详情</h2><p>{selectedTask.task?.title ?? ''} · {shortId(selectedTask.task?.id ?? '')}</p></div><button className="icon-button" onClick={() => setSelectedTask(null)}><X size={17}/></button></div><pre>{JSON.stringify(selectedTask, null, 2)}</pre></section>}
        <p className="footnote">业务状态以 Supabase RPC 返回为准。Worker 身份目前为项目内逻辑身份，不构成独立会话隔离。</p>
      </>}
    </main>
    {showProject && <Modal title="创建项目" onClose={() => setShowProject(false)}><form onSubmit={createProject}><label>项目名称<input value={projectForm.name} onChange={e => setProjectForm({...projectForm,name:e.target.value})} required maxLength={120}/></label><label>GitHub 仓库（可选）<input value={projectForm.github_repo} onChange={e => setProjectForm({...projectForm,github_repo:e.target.value})} placeholder="owner/repository"/></label><label>项目说明<textarea value={projectForm.description} onChange={e => setProjectForm({...projectForm,description:e.target.value})}/></label><div className="modal-actions"><button type="button" className="secondary" onClick={() => setShowProject(false)}>取消</button><button className="primary" disabled={busy}>{busy ? '创建中…' : '创建项目'}</button></div></form></Modal>}
    {showWorker && <Modal title="注册 Worker" onClose={() => setShowWorker(false)}><form onSubmit={createWorker}><label>Worker Key<input value={workerForm.worker_key} onChange={e => setWorkerForm({...workerForm,worker_key:e.target.value})} placeholder="worker-architect" required/></label><label>显示名称<input value={workerForm.display_name} onChange={e => setWorkerForm({...workerForm,display_name:e.target.value})} placeholder="Architect" required/></label><label>职责说明<textarea value={workerForm.description} onChange={e => setWorkerForm({...workerForm,description:e.target.value})}/></label><div className="modal-actions"><button type="button" className="secondary" onClick={() => setShowWorker(false)}>取消</button><button className="primary" disabled={busy}>{busy ? '保存中…' : '注册 Worker'}</button></div></form></Modal>}
    {showTask && <Modal title="发布实现任务" onClose={() => setShowTask(false)}><form onSubmit={createTask}><label>任务标题<input value={taskForm.title} onChange={e => setTaskForm({...taskForm,title:e.target.value})} required/></label><label>任务描述<textarea value={taskForm.description} onChange={e => setTaskForm({...taskForm,description:e.target.value})} required/></label><label>验收要求（JSON）<textarea className="code-input" value={taskForm.requirements} onChange={e => setTaskForm({...taskForm,requirements:e.target.value})} placeholder={'{\n  "acceptance": ["..."]\n}'}/></label><label>优先级<input type="number" value={taskForm.priority} onChange={e => setTaskForm({...taskForm,priority:e.target.value})}/></label><label className="check-label"><input type="checkbox" checked={taskForm.requires_review} onChange={e => setTaskForm({...taskForm,requires_review:e.target.checked})}/> 需要 Reviewer 审核</label><div className="modal-actions"><button type="button" className="secondary" onClick={() => setShowTask(false)}>取消</button><button className="primary" disabled={busy || workers.length === 0}>{busy ? '发布中…' : '发布任务'}</button></div></form></Modal>}
  </div>
}

function Stat({label,value,icon}:{label:string;value:number;icon:ReactNode}) { return <div className="stat-card"><div className="stat-icon">{icon}</div><span>{label}</span><strong>{value}</strong></div> }
function Status({value}:{value:string}) { return <span className={`status status-${value}`}>{statusLabel(value)}</span> }
function Empty({text}:{text:string}) { return <div className="empty-state">{text}</div> }
function Modal({title,children,onClose}:{title:string;children:ReactNode;onClose:()=>void}) { return <div className="modal-backdrop" onMouseDown={e => { if(e.target===e.currentTarget) onClose() }}><section className="modal"><div className="modal-head"><h2>{title}</h2><button className="icon-button" onClick={onClose}><X size={17}/></button></div>{children}</section></div> }
