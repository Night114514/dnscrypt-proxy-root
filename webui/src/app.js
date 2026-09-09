(function startDnscryptApp(windowObject) {
  'use strict';

  const documentObject = windowObject.document;
  const bridge = windowObject.DnscryptBridge;
  const byId = (id) => documentObject.getElementById(id);
  const translations = {
    en: {
      'bridge.checking': 'Checking bridge', 'bridge.ready': 'Root bridge connected', 'bridge.missing': 'Root bridge unavailable',
      'common.unknown': 'Unknown', 'common.clean': 'Clean', 'common.modified': 'Modified',
      'dynamic.running': 'Running', 'dynamic.stopped': 'Stopped', 'dynamic.yes': 'Yes', 'dynamic.no': 'No',
      'dynamic.applied': 'Applied', 'dynamic.pending': 'Pending', 'dynamic.unavailable': 'Unavailable',
      'dynamic.none': 'None', 'dynamic.online': 'Online', 'dynamic.offline': 'Offline',
      'dynamic.healthy': 'Healthy', 'dynamic.degraded': 'Degraded', 'dynamic.strict': 'Strict',
      'dynamic.upstream_only': 'Upstream only', 'dynamic.present': 'Present', 'dynamic.absent': 'Absent',
      'dynamic.policyAffected': 'Strict mode redirected this destination query. This is not a “direct DNS” policy-bypass test.',
      'dynamic.directDestination': 'The module did not globally redirect this destination query; the result still represents only this sample.',
    },
    'zh-Hant': {
      'bridge.checking': '正在檢查橋接', 'bridge.ready': 'Root 橋接已連線', 'bridge.missing': 'Root 橋接不可用',
      'common.refresh': '重新整理', 'common.unknown': '未知', 'common.clean': '未修改', 'common.modified': '已修改',
      'common.load': '載入', 'common.save': '儲存', 'common.localOnly': '僅限本機裝置',
      'nav.overview': '總覽', 'nav.configuration': '設定檔', 'nav.lists': '管理清單', 'nav.resolvers': '解析器',
      'nav.diagnostics': '診斷', 'nav.statistics': '統計', 'nav.logs': '日誌', 'nav.updates': '更新',
      'nav.backup': '備份與還原', 'nav.about': '關於',
      'overview.eyebrow': '執行期真實狀態', 'overview.title': '服務總覽',
      'overview.subtitle': '顯示 Root 控制腳本回報的即時狀態，不由 WebUI 猜測。',
      'overview.pendingTitle': 'Canonical 變更尚待套用。', 'overview.pendingBody': '重新啟動服務，才會把已儲存的 generation 發佈給 daemon。',
      'overview.serviceActions': '服務操作', 'overview.serviceHelp': '後端鎖會序列化所有生命週期操作。',
      'overview.integrationMode': 'Android DNS 整合', 'overview.integrationHelp': '嚴格模式會重新導向裝置 DNS；僅上游模式不改全域路由。',
      'overview.runtimeDetails': '執行期詳情', 'overview.runtimeDetailsHelp': '診斷啟動失敗或策略錯誤時可使用的證據。',
      'status.service': '服務', 'status.health': '健康狀態', 'status.mode': 'DNS 模式', 'status.upstream': '上游',
      'detail.manager': '管理器', 'detail.version': 'Daemon 版本', 'detail.uid': '執行 UID', 'detail.listener': 'TCP + UDP 監聽',
      'detail.failure': '最近啟動失敗', 'detail.config': 'Canonical 設定檔',
      'action.start': '啟動', 'action.restart': '重新啟動', 'action.stop': '停止',
      'action.reloadCanonical': '重新載入 canonical', 'action.savePending': '儲存（待套用）', 'action.saveRestart': '儲存並重啟',
      'action.saveApply': '儲存並套用', 'action.downloadMerge': '下載並合併', 'action.applyPreset': '套用預設',
      'action.measure': '量測', 'action.applyRestart': '套用並重啟', 'action.runTest': '執行測試',
      'action.runSample': '執行抽樣檢查', 'action.checkUpdate': '檢查', 'action.installUpdate': '檢查並安裝',
      'action.downloadBackup': '下載備份', 'action.validateImport': '驗證並匯入',
      'configuration.eyebrow': 'Canonical TOML', 'configuration.title': '設定檔編輯器',
      'configuration.subtitle': '後端會強制 UID 3003，並在取代 canonical 檔案前驗證 staged 檔。',
      'configuration.pendingTitle': '儲存不等於套用。', 'configuration.pendingBody': '成功儲存後，仍要等下次成功重新啟動才會套用。',
      'lists.eyebrow': 'Root 擁有的單一真實來源', 'lists.title': '管理清單',
      'lists.subtitle': '讀寫一律經過驗證後端；WebUI 不直接讀取任何模組路徑。', 'lists.kind': '清單',
      'lists.applyHelp': '「儲存並套用」要求目前沒有待套用 generation；它會重新啟動運行中的 daemon，若新 generation 失敗則還原上一份可工作的清單。',
      'lists.subscriptions': '封鎖清單訂閱', 'lists.subscriptionsHelp': '嚴格 JSON 陣列：每個物件只可包含 HTTPS url 與布林 enabled；下載內容只會合併到有標記的受管理區段。',
      'resolvers.eyebrow': '上游選擇', 'resolvers.title': '解析器與預設', 'resolvers.subtitle': '解析器變更會先驗證，再透過受控重新啟動套用。',
      'resolvers.fastest': '不要求過濾的低延遲預設。', 'resolvers.privacy': '要求無日誌及 DNSSEC 的私隱導向預設。',
      'resolvers.family': '家庭安全過濾解析器預設。', 'resolvers.custom': '自訂解析器名稱', 'resolvers.customHelp': '使用設定來源中的名稱，以逗號分隔。',
      'diagnostics.eyebrow': '有界限的檢查', 'diagnostics.title': 'DNS 診斷', 'diagnostics.subtitle': '這些是針對本裝置的檢查，並非全域私隱認證。',
      'diagnostics.query': '解析結果比較', 'diagnostics.queryHelp': '在目前 Android 策略下，比較本機監聽器與指定 DNS 目的地。',
      'diagnostics.domain': '網域', 'diagnostics.leak': '抽樣路由檢查', 'diagnostics.leakHelp': '觸發四個隨機查詢，再抽樣已設定的 query/NX 日誌。',
      'diagnostics.leakLimit': '此檢查只涵蓋本頁觸發的樣本；不能證明所有 App 都使用 DNSCrypt，而且在僅上游模式下不適用於判斷全域路由。',
      'diagnostics.protocol': '協定狀態', 'diagnostics.protocolHelp': '已設定的協定組合與最近一次記錄的上游可達性。',
      'statistics.eyebrow': '已設定的查詢日誌', 'statistics.title': '查詢統計', 'statistics.subtitle': '只解析有效的 dnscrypt-proxy TSV 列；格式錯誤的列會忽略。',
      'statistics.total': '查詢總數', 'statistics.blocked': '已封鎖', 'statistics.rate': '封鎖率', 'statistics.unique': '獨立網域',
      'statistics.topDomains': '最多查詢網域', 'statistics.topBlocked': '最多封鎖網域',
      'logs.eyebrow': '有界限的日誌讀取器', 'logs.title': '服務日誌', 'logs.subtitle': '後端會拒絕不安全路徑，並限制要求的行數。',
      'updates.eyebrow': '已驗證的上游二進位檔', 'updates.title': 'dnscrypt-proxy 更新',
      'updates.subtitle': '更新器會驗證 release asset digest、二進位版本、設定檢查與 atomic rollback 路徑。', 'updates.installed': '已安裝 daemon',
      'backup.eyebrow': 'Generation manifest v2', 'backup.title': '備份與還原', 'backup.subtitle': '把 TOML、四份管理清單和訂閱匯出為一份嚴格 manifest。',
      'backup.export': '匯出 generation', 'backup.exportHelp': '下載本機 JSON 備份；匯入時刻意不變更 Android DNS 整合模式。',
      'backup.import': '匯入 generation', 'backup.importHelp': '完整 staged generation 必須先通過驗證，才會變更任何 canonical 檔案。',
      'backup.pendingTitle': '匯入資料仍然待套用。', 'backup.pendingBody': '檢視結果後再重新啟動；commit 失敗會還原完整的上一代。',
      'about.title': '關於此控制平面', 'about.subtitle': 'dnscrypt-proxy-root Android 模組的零依賴、可重現 WebUI。',
      'about.security': '安全邊界', 'about.securityBody': 'WebUI 只要求 allowlisted 操作；Root shell 仍負責驗證、鎖定、擁有權檢查與回滾。',
      'about.license': '授權', 'about.licenseBody': '專案程式碼採 MIT；模組 ZIP 會一併提供第三方聲明與授權全文。',
      'about.deviceEvidence': '裝置證據', 'about.deviceEvidenceBody': '桌面 shell 測試不能取代公開的實體裝置驗收矩陣；正式部署前請查閱 REAL_DEVICE_ACCEPTANCE.md。',
      'dynamic.running': '運行中', 'dynamic.stopped': '已停止', 'dynamic.yes': '是', 'dynamic.no': '否',
      'dynamic.applied': '已套用', 'dynamic.pending': '待套用', 'dynamic.unavailable': '不可用',
      'dynamic.policyAffected': '嚴格模式已重新導向這個目的地查詢；這不是繞過策略的「直接 DNS」測試。',
      'dynamic.directDestination': '此目的地查詢未受模組全域重新導向；結果仍只代表本次樣本。',
    },
    'zh-Hans': {
      'bridge.checking': '正在检查桥接', 'bridge.ready': 'Root 桥接已连接', 'bridge.missing': 'Root 桥接不可用',
      'common.refresh': '刷新', 'common.unknown': '未知', 'common.clean': '未修改', 'common.modified': '已修改',
      'common.load': '加载', 'common.save': '保存', 'common.localOnly': '仅限本机设备',
      'nav.overview': '概览', 'nav.configuration': '配置文件', 'nav.lists': '管理列表', 'nav.resolvers': '解析器',
      'nav.diagnostics': '诊断', 'nav.statistics': '统计', 'nav.logs': '日志', 'nav.updates': '更新', 'nav.backup': '备份与恢复', 'nav.about': '关于',
      'overview.eyebrow': '运行时真实状态', 'overview.title': '服务概览', 'overview.subtitle': '显示 Root 控制脚本报告的实时状态，不由 WebUI 猜测。',
      'overview.pendingTitle': 'Canonical 更改尚未应用。', 'overview.pendingBody': '重启服务后，保存的 generation 才会发布给 daemon。',
      'overview.serviceActions': '服务操作', 'overview.serviceHelp': '后端锁会串行化所有生命周期操作。',
      'overview.integrationMode': 'Android DNS 集成', 'overview.integrationHelp': '严格模式会重定向设备 DNS；仅上游模式不改全局路由。',
      'overview.runtimeDetails': '运行时详情', 'overview.runtimeDetailsHelp': '诊断启动失败或策略错误时可使用的证据。',
      'status.service': '服务', 'status.health': '健康状态', 'status.mode': 'DNS 模式', 'status.upstream': '上游',
      'detail.manager': '管理器', 'detail.version': 'Daemon 版本', 'detail.uid': '运行 UID', 'detail.listener': 'TCP + UDP 监听',
      'detail.failure': '最近启动失败', 'detail.config': 'Canonical 配置',
      'action.start': '启动', 'action.restart': '重启', 'action.stop': '停止', 'action.reloadCanonical': '重新加载 canonical',
      'action.savePending': '保存（待应用）', 'action.saveRestart': '保存并重启', 'action.saveApply': '保存并应用',
      'action.downloadMerge': '下载并合并', 'action.applyPreset': '应用预设', 'action.measure': '测量', 'action.applyRestart': '应用并重启',
      'action.runTest': '运行测试', 'action.runSample': '运行抽样检查', 'action.checkUpdate': '检查', 'action.installUpdate': '检查并安装',
      'action.downloadBackup': '下载备份', 'action.validateImport': '验证并导入',
      'configuration.eyebrow': 'Canonical TOML', 'configuration.title': '配置编辑器',
      'configuration.subtitle': '后端强制 UID 3003，并在替换 canonical 文件前验证 staged 文件。',
      'configuration.pendingTitle': '保存不等于应用。', 'configuration.pendingBody': '成功保存后，仍要等下次成功重启才会应用。',
      'lists.eyebrow': 'Root 拥有的单一真实来源', 'lists.title': '管理列表', 'lists.subtitle': '读写全部经过验证后端；WebUI 不直接读取模块路径。',
      'lists.kind': '列表', 'lists.applyHelp': '“保存并应用”要求当前没有待应用 generation；它会重启运行中的 daemon，若新 generation 失败则恢复上一份可用列表。',
      'lists.subscriptions': '屏蔽列表订阅', 'lists.subscriptionsHelp': '严格 JSON 数组：每个对象只能包含 HTTPS url 与布尔 enabled；下载内容只合并到带标记的受管区段。',
      'resolvers.eyebrow': '上游选择', 'resolvers.title': '解析器与预设', 'resolvers.subtitle': '解析器更改先验证，再通过受控重启应用。',
      'resolvers.fastest': '不要求过滤的低延迟预设。', 'resolvers.privacy': '要求无日志和 DNSSEC 的隐私导向预设。',
      'resolvers.family': '家庭安全过滤解析器预设。', 'resolvers.custom': '自定义解析器名称', 'resolvers.customHelp': '使用配置来源中的名称，以逗号分隔。',
      'diagnostics.eyebrow': '有界检查', 'diagnostics.title': 'DNS 诊断', 'diagnostics.subtitle': '这些是针对本设备的检查，并非全局隐私认证。',
      'diagnostics.query': '解析结果比较', 'diagnostics.queryHelp': '在当前 Android 策略下，比较本地监听器与指定 DNS 目的地。',
      'diagnostics.domain': '域名', 'diagnostics.leak': '抽样路由检查', 'diagnostics.leakHelp': '触发四个随机查询，再抽样已配置的 query/NX 日志。',
      'diagnostics.leakLimit': '此检查只覆盖本页触发的样本；不能证明所有 App 都使用 DNSCrypt，并且仅上游模式下不适用于判断全局路由。',
      'diagnostics.protocol': '协议状态', 'diagnostics.protocolHelp': '已配置的协议组合与最近记录的上游可达性。',
      'statistics.eyebrow': '已配置的查询日志', 'statistics.title': '查询统计', 'statistics.subtitle': '只解析有效 dnscrypt-proxy TSV 行；格式错误的行会被忽略。',
      'statistics.total': '查询总数', 'statistics.blocked': '已屏蔽', 'statistics.rate': '屏蔽率', 'statistics.unique': '独立域名',
      'statistics.topDomains': '最多查询域名', 'statistics.topBlocked': '最多屏蔽域名',
      'logs.eyebrow': '有界日志读取器', 'logs.title': '服务日志', 'logs.subtitle': '后端拒绝不安全路径，并限制请求的行数。',
      'updates.eyebrow': '已验证的上游二进制', 'updates.title': 'dnscrypt-proxy 更新',
      'updates.subtitle': '更新器验证 release asset digest、二进制版本、配置检查与原子回滚路径。', 'updates.installed': '已安装 daemon',
      'backup.eyebrow': 'Generation manifest v2', 'backup.title': '备份与恢复', 'backup.subtitle': '把 TOML、四份管理列表与订阅导出成一份严格 manifest。',
      'backup.export': '导出 generation', 'backup.exportHelp': '下载本地 JSON 备份；导入不会改变 Android DNS 集成模式。',
      'backup.import': '导入 generation', 'backup.importHelp': '完整 staged generation 必须先通过验证，才会更改任何 canonical 文件。',
      'backup.pendingTitle': '导入数据仍待应用。', 'backup.pendingBody': '检查结果后再重启；提交失败会恢复完整上一代。',
      'about.title': '关于此控制平面', 'about.subtitle': 'dnscrypt-proxy-root Android 模块的零依赖、可重现 WebUI。',
      'about.security': '安全边界', 'about.securityBody': 'WebUI 只请求允许列表内的操作；Root shell 仍负责验证、锁、所有权检查和回滚。',
      'about.license': '许可', 'about.licenseBody': '项目代码采用 MIT；模块 ZIP 同时提供第三方声明及许可证全文。',
      'about.deviceEvidence': '设备证据', 'about.deviceEvidenceBody': '桌面 shell 测试不能取代公开的实体设备验收矩阵；正式部署前请查看 REAL_DEVICE_ACCEPTANCE.md。',
      'dynamic.running': '运行中', 'dynamic.stopped': '已停止', 'dynamic.yes': '是', 'dynamic.no': '否',
      'dynamic.applied': '已应用', 'dynamic.pending': '待应用', 'dynamic.unavailable': '不可用',
      'dynamic.policyAffected': '严格模式已重定向这个目的地查询；这不是绕过策略的“直接 DNS”测试。',
      'dynamic.directDestination': '此目的地查询未受模块全局重定向；结果仍只代表本次样本。',
    },
  };

  let locale = 'en';
  let latestStatus = null;
  let configBaseline = '';
  let listBaseline = '';

  function storedValue(key) {
    try { return windowObject.localStorage.getItem(key); } catch (_) { return null; }
  }

  function storeValue(key, value) {
    try { windowObject.localStorage.setItem(key, value); } catch (_) { /* optional preference */ }
  }

  function t(key) {
    return (translations[locale] && translations[locale][key]) || translations.en[key] || key;
  }

  function setLocale(nextLocale) {
    locale = translations[nextLocale] ? nextLocale : 'en';
    documentObject.documentElement.lang = locale;
    byId('languageSelect').value = locale;
    documentObject.querySelectorAll('[data-i18n]').forEach((element) => {
      if (!element.dataset.i18nDefault) element.dataset.i18nDefault = element.textContent;
      const translated = translations[locale] && translations[locale][element.dataset.i18n];
      element.textContent = translated || element.dataset.i18nDefault;
    });
    storeValue('dpr-locale', locale);
    if (latestStatus) renderStatus(latestStatus);
    updateDirtyStates();
  }

  function toast(message, kind = 'success') {
    const node = documentObject.createElement('div');
    node.className = `toast ${kind}`;
    node.textContent = String(message);
    byId('toastRegion').appendChild(node);
    windowObject.setTimeout(() => node.remove(), 4200);
  }

  function errorMessage(error) {
    return error && error.message ? error.message : String(error);
  }

  async function runBusy(button, operation, options = {}) {
    const buttons = button ? [button] : [];
    buttons.forEach((item) => { item.disabled = true; item.setAttribute('aria-busy', 'true'); });
    try {
      const result = await operation();
      if (options.toast !== false && typeof result === 'string' && result.trim()) toast(result.trim());
      if (options.refreshStatus !== false) await refreshStatus({quiet: true});
      return result;
    } catch (error) {
      toast(errorMessage(error), 'error');
      throw error;
    } finally {
      buttons.forEach((item) => { item.disabled = false; item.removeAttribute('aria-busy'); });
    }
  }

  function dynamicValue(value) {
    const key = `dynamic.${value}`;
    return t(key) === key ? String(value || '—').replace(/_/g, ' ') : t(key);
  }

  function booleanValue(value) { return value ? t('dynamic.yes') : t('dynamic.no'); }

  function setMetric(id, value, tone = '') {
    const element = byId(id);
    element.textContent = value || '—';
    element.className = tone;
  }

  function renderStatus(status) {
    latestStatus = status;
    const running = status.running === true;
    const state = String(status.service_state || 'unknown');
    const healthy = status.healthy === true;
    const hero = byId('heroState');
    hero.className = `hero-state ${state === 'healthy' ? 'healthy' : state === 'degraded' ? 'degraded' : running ? 'fault' : 'stopped'}`;
    hero.lastElementChild.textContent = dynamicValue(state);

    setMetric('statusService', running ? t('dynamic.running') : t('dynamic.stopped'), running ? 'good' : 'bad');
    byId('statusPid').textContent = `PID ${status.pid || '—'}`;
    setMetric('statusHealth', dynamicValue(state), healthy ? (state === 'degraded' ? 'warn' : 'good') : 'bad');
    byId('statusLocalDns').textContent = `Local DNS ${booleanValue(status.local_dns === true)}`;
    setMetric('statusMode', dynamicValue(status.dns_mode), status.dns_mode === 'strict' ? 'good' : 'warn');
    byId('statusFirewall').textContent = `Firewall ${dynamicValue(status.firewall)}`;
    setMetric('statusUpstream', dynamicValue(status.upstream), status.upstream === 'online' ? 'good' : 'warn');
    byId('statusApply').textContent = `Apply ${dynamicValue(status.config_apply_state)}`;

    byId('pendingNotice').classList.toggle('hidden', status.config_apply_state !== 'pending');
    byId('detailManager').textContent = status.manager || '—';
    byId('detailVersion').textContent = status.version || '—';
    byId('detailUid').textContent = status.uid || '—';
    byId('detailListener').textContent = `${booleanValue(status.listener === true)} / Local DNS ${booleanValue(status.local_dns === true)}`;
    byId('detailFailure').textContent = dynamicValue(status.start_failure || 'none');
    byId('detailConfig').textContent = status.config || '—';
    byId('installedVersion').textContent = status.version || '—';
    byId('sidebarVersion').textContent = `v0.9.2 · ${status.version || 'daemon —'}`;
    byId('updateSummary').textContent = [status.update_state, status.update_message, status.update_time].filter(Boolean).join(' · ') || '—';
    documentObject.querySelectorAll('[data-dns-mode]').forEach((button) => button.classList.toggle('active', button.dataset.dnsMode === status.dns_mode));
  }

  async function refreshStatus({quiet = false} = {}) {
    if (!bridge || !bridge.available()) return null;
    try {
      const status = await bridge.status();
      renderStatus(status);
      return status;
    } catch (error) {
      if (!quiet) toast(errorMessage(error), 'error');
      return null;
    }
  }

  function updateDirtyStates() {
    const configDirty = byId('configEditor').value !== configBaseline;
    const listDirty = byId('listEditor').value !== listBaseline;
    byId('configDirty').textContent = configDirty ? t('common.modified') : t('common.clean');
    byId('configDirty').classList.toggle('dirty', configDirty);
    byId('listDirty').textContent = listDirty ? t('common.modified') : t('common.clean');
    byId('listDirty').classList.toggle('dirty', listDirty);
  }

  async function loadConfig() {
    const content = await bridge.control('get-config');
    configBaseline = content;
    byId('configEditor').value = content;
    updateDirtyStates();
    return '';
  }

  async function saveConfig() {
    const content = byId('configEditor').value;
    const result = await bridge.control('save-config-b64', [bridge.encodeText(content)]);
    configBaseline = content;
    updateDirtyStates();
    return result;
  }

  async function loadList() {
    const content = await bridge.getList(byId('listKind').value);
    listBaseline = content;
    byId('listEditor').value = content;
    updateDirtyStates();
    return '';
  }

  async function saveList(apply) {
    const content = byId('listEditor').value;
    const result = await bridge.saveList(byId('listKind').value, content, apply);
    listBaseline = content;
    updateDirtyStates();
    return result;
  }

  async function loadSubscriptions() {
    const output = await bridge.control('get-subscriptions');
    byId('subscriptionsEditor').value = output.trim() || '[]';
    return '';
  }

  async function loadResolvers() {
    const [names, mode] = await Promise.all([bridge.control('list-resolvers'), bridge.control('get-mode')]);
    byId('resolverEditor').value = names.trim().split(/\s+/).filter(Boolean).join(', ');
    byId('currentPreset').textContent = mode.trim() || 'custom';
    return '';
  }

  function prettyOutput(output) {
    const trimmed = String(output || '').trim();
    if (!trimmed) return '';
    try { return JSON.stringify(JSON.parse(trimmed), null, 2); } catch (_) { return trimmed; }
  }

  function renderRankList(target, rows) {
    target.replaceChildren();
    (Array.isArray(rows) ? rows : []).slice(0, 12).forEach((row) => {
      const item = documentObject.createElement('div');
      item.className = 'rank-row';
      const name = documentObject.createElement('span');
      name.textContent = String(row.domain || row.hour || '—');
      const count = documentObject.createElement('strong');
      count.textContent = String(row.count ?? row.queries ?? 0);
      item.append(name, count);
      target.appendChild(item);
    });
    if (!target.children.length) target.textContent = '—';
  }

  async function loadStatistics() {
    const stats = JSON.parse(await bridge.control('query-stats'));
    byId('statsTotal').textContent = String(stats.totalQueries ?? 0);
    byId('statsBlocked').textContent = String(stats.blockedCount ?? 0);
    byId('statsRate').textContent = `${stats.blockRate ?? 0}%`;
    byId('statsUnique').textContent = String(stats.uniqueDomains ?? 0);
    renderRankList(byId('topDomains'), stats.topDomains);
    renderRankList(byId('topBlocked'), stats.topBlocked);
    return '';
  }

  function showView(viewName) {
    const validPanel = Array.from(documentObject.querySelectorAll('[data-view-panel]'))
      .find((panel) => panel.dataset.viewPanel === viewName);
    const selected = validPanel ? viewName : 'overview';
    documentObject.querySelectorAll('[data-view-panel]').forEach((panel) => panel.classList.toggle('active', panel.dataset.viewPanel === selected));
    documentObject.querySelectorAll('[data-view]').forEach((button) => button.classList.toggle('active', button.dataset.view === selected));
    documentObject.title = `${selected[0].toUpperCase()}${selected.slice(1)} · DNSCrypt Proxy Root`;
    closeMenu();
    if (windowObject.location.hash !== `#${selected}`) {
      try { windowObject.history.replaceState(null, '', `#${selected}`); }
      catch (_) { windowObject.location.hash = selected; }
    }
    if (!bridge || !bridge.available()) return;
    if (selected === 'configuration' && !byId('configEditor').value) runBusy(null, loadConfig, {toast: false, refreshStatus: false}).catch(() => {});
    if (selected === 'lists' && !byId('listEditor').value) runBusy(null, () => Promise.all([loadList(), loadSubscriptions()]), {toast: false, refreshStatus: false}).catch(() => {});
    if (selected === 'resolvers' && !byId('resolverEditor').value) runBusy(null, loadResolvers, {toast: false, refreshStatus: false}).catch(() => {});
  }

  function closeMenu() {
    byId('sidebar').classList.remove('open');
    byId('scrim').classList.remove('open');
    byId('menuButton').setAttribute('aria-expanded', 'false');
  }

  function initializeTheme() {
    const stored = storedValue('dpr-theme');
    const prefersLight = windowObject.matchMedia && windowObject.matchMedia('(prefers-color-scheme: light)').matches;
    const theme = stored === 'light' || stored === 'dark' ? stored : (prefersLight ? 'light' : 'dark');
    documentObject.documentElement.dataset.theme = theme;
  }

  function readFileText(file) {
    if (file && typeof file.text === 'function') return file.text();
    return new Promise((resolve, reject) => {
      const reader = new windowObject.FileReader();
      reader.addEventListener('load', () => resolve(String(reader.result || '')));
      reader.addEventListener('error', () => reject(reader.error || new Error('Unable to read the selected backup')));
      reader.readAsText(file, 'UTF-8');
    });
  }

  function bindEvents() {
    documentObject.querySelectorAll('[data-view]').forEach((button) => button.addEventListener('click', () => showView(button.dataset.view)));
    windowObject.addEventListener('hashchange', () => showView(windowObject.location.hash.slice(1)));
    byId('menuButton').addEventListener('click', () => {
      const open = !byId('sidebar').classList.contains('open');
      byId('sidebar').classList.toggle('open', open);
      byId('scrim').classList.toggle('open', open);
      byId('menuButton').setAttribute('aria-expanded', String(open));
    });
    byId('scrim').addEventListener('click', closeMenu);
    byId('themeButton').addEventListener('click', () => {
      const next = documentObject.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
      documentObject.documentElement.dataset.theme = next;
      storeValue('dpr-theme', next);
    });
    byId('languageSelect').addEventListener('change', (event) => setLocale(event.target.value));
    byId('refreshButton').addEventListener('click', (event) => runBusy(event.currentTarget, () => refreshStatus()).catch(() => {}));

    documentObject.querySelectorAll('[data-control-action]').forEach((button) => button.addEventListener('click', () => {
      runBusy(button, () => bridge.control(button.dataset.controlAction)).catch(() => {});
    }));
    documentObject.querySelectorAll('[data-dns-mode]').forEach((button) => button.addEventListener('click', () => {
      runBusy(button, () => bridge.control('set-dns-mode', [button.dataset.dnsMode])).catch(() => {});
    }));

    byId('configEditor').addEventListener('input', updateDirtyStates);
    byId('loadConfigButton').addEventListener('click', (event) => runBusy(event.currentTarget, loadConfig, {toast: false, refreshStatus: false}).catch(() => {}));
    byId('saveConfigButton').addEventListener('click', (event) => runBusy(event.currentTarget, saveConfig).catch(() => {}));
    byId('saveRestartConfigButton').addEventListener('click', (event) => runBusy(event.currentTarget, async () => {
      const saved = await saveConfig();
      try { return `${saved.trim()}\n${(await bridge.control('restart')).trim()}`; }
      catch (error) { throw new Error(`Configuration was saved, but restart failed: ${errorMessage(error)}`); }
    }).catch(() => {}));

    byId('listEditor').addEventListener('input', updateDirtyStates);
    byId('listKind').addEventListener('change', () => runBusy(null, loadList, {toast: false, refreshStatus: false}).catch(() => {}));
    byId('loadListButton').addEventListener('click', (event) => runBusy(event.currentTarget, loadList, {toast: false, refreshStatus: false}).catch(() => {}));
    byId('saveListButton').addEventListener('click', (event) => runBusy(event.currentTarget, () => saveList(false)).catch(() => {}));
    byId('applyListButton').addEventListener('click', (event) => runBusy(event.currentTarget, () => saveList(true)).catch(() => {}));
    byId('loadSubscriptionsButton').addEventListener('click', (event) => runBusy(event.currentTarget, loadSubscriptions, {toast: false, refreshStatus: false}).catch(() => {}));
    byId('saveSubscriptionsButton').addEventListener('click', (event) => runBusy(event.currentTarget, () => bridge.control('save-subscriptions-b64', [bridge.encodeText(byId('subscriptionsEditor').value)])).catch(() => {}));
    byId('applySubscriptionsButton').addEventListener('click', (event) => runBusy(event.currentTarget, () => bridge.control('apply-subscriptions')).catch(() => {}));

    documentObject.querySelectorAll('[data-preset]').forEach((button) => button.addEventListener('click', () => runBusy(button, async () => {
      const output = await bridge.control('quick-mode', [button.dataset.preset]);
      await loadResolvers();
      return output;
    }).catch(() => {})));
    byId('loadResolversButton').addEventListener('click', (event) => runBusy(event.currentTarget, loadResolvers, {toast: false, refreshStatus: false}).catch(() => {}));
    byId('saveResolversButton').addEventListener('click', (event) => runBusy(event.currentTarget, async () => {
      const names = byId('resolverEditor').value;
      const saved = await bridge.control('set-resolvers', [names]);
      try { return `${saved.trim()}\n${(await bridge.control('restart')).trim()}`; }
      catch (error) { throw new Error(`Resolver names were saved, but restart failed: ${errorMessage(error)}`); }
    }).catch(() => {}));
    byId('pingResolversButton').addEventListener('click', (event) => runBusy(event.currentTarget, async () => {
      byId('resolverResult').textContent = prettyOutput(await bridge.control('ping-all'));
      return '';
    }, {toast: false, refreshStatus: false}).catch(() => {}));

    byId('runDnsTestButton').addEventListener('click', (event) => runBusy(event.currentTarget, async () => {
      const data = JSON.parse(await bridge.control('dns-test', [byId('diagnosticDomain').value.trim()]));
      const transformed = {
        domain: data.domain,
        local_listener_result: data.result,
        destination_query_result: data.direct,
        comparison_scope: data.comparison_scope,
        local_latency_ms: data.latency_ms,
        local_server: data.server,
      };
      byId('dnsTestResult').textContent = JSON.stringify(transformed, null, 2);
      const scope = byId('comparisonScope');
      scope.textContent = data.comparison_scope === 'policy_affected' ? t('dynamic.policyAffected') : t('dynamic.directDestination');
      scope.classList.remove('hidden');
      return '';
    }, {toast: false, refreshStatus: false}).catch(() => {}));
    byId('runLeakTestButton').addEventListener('click', (event) => runBusy(event.currentTarget, async () => {
      byId('leakTestResult').textContent = prettyOutput(await bridge.control('leak-test'));
      return '';
    }, {toast: false, refreshStatus: false}).catch(() => {}));
    byId('protocolStatusButton').addEventListener('click', (event) => runBusy(event.currentTarget, async () => {
      byId('protocolResult').textContent = prettyOutput(await bridge.control('protocol-status'));
      return '';
    }, {toast: false, refreshStatus: false}).catch(() => {}));

    byId('statsRefreshButton').addEventListener('click', (event) => runBusy(event.currentTarget, loadStatistics, {toast: false, refreshStatus: false}).catch(() => {}));
    byId('logsRefreshButton').addEventListener('click', (event) => runBusy(event.currentTarget, async () => {
      byId('logsResult').textContent = await bridge.control('logs', [byId('logLines').value]);
      return '';
    }, {toast: false, refreshStatus: false}).catch(() => {}));

    byId('checkUpdateButton').addEventListener('click', (event) => runBusy(event.currentTarget, async () => {
      const output = await bridge.control('check-update');
      byId('updateResult').textContent = output;
      return output;
    }).catch(() => {}));
    byId('installUpdateButton').addEventListener('click', (event) => runBusy(event.currentTarget, async () => {
      const output = await bridge.control('update');
      byId('updateResult').textContent = output;
      return output;
    }).catch(() => {}));

    byId('exportButton').addEventListener('click', (event) => runBusy(event.currentTarget, async () => {
      const manifest = await bridge.control('export-config');
      const parsed = JSON.parse(manifest);
      if (![1, 2].includes(parsed.version)) throw new Error('Backend returned an unsupported backup schema');
      const blob = new windowObject.Blob([manifest], {type: 'application/json'});
      const link = documentObject.createElement('a');
      link.href = windowObject.URL.createObjectURL(blob);
      link.download = `dnscrypt-proxy-root-v0.9.2-${new Date().toISOString().slice(0, 10)}.json`;
      link.click();
      windowObject.setTimeout(() => windowObject.URL.revokeObjectURL(link.href), 1000);
      byId('backupResult').textContent = `Exported generation schema v${parsed.version}.`;
      return 'Backup downloaded.';
    }).catch(() => {}));
    byId('importButton').addEventListener('click', (event) => runBusy(event.currentTarget, async () => {
      const file = byId('importFile').files && byId('importFile').files[0];
      if (!file) throw new Error('Choose a JSON backup first');
      const manifest = await readFileText(file);
      const parsed = JSON.parse(manifest);
      if (![1, 2].includes(parsed.version)) throw new Error('Unsupported backup schema version');
      if (!windowObject.confirm('Validate and import this complete canonical generation? It will remain pending until restart.')) return '';
      const output = await bridge.control('import-config-b64', [bridge.encodeText(manifest)]);
      byId('backupResult').textContent = output;
      return output;
    }).catch(() => {}));
  }

  function initialize() {
    initializeTheme();
    const preferredLocale = storedValue('dpr-locale') || (windowObject.navigator.language.toLowerCase().includes('zh') ? (windowObject.navigator.language.toLowerCase().includes('tw') || windowObject.navigator.language.toLowerCase().includes('hk') ? 'zh-Hant' : 'zh-Hans') : 'en');
    setLocale(preferredLocale);
    bindEvents();
    showView(windowObject.location.hash.slice(1) || 'overview');
    const bridgeState = byId('bridgeState');
    if (bridge && bridge.available()) {
      bridgeState.classList.add('ready');
      bridgeState.lastElementChild.textContent = t('bridge.ready');
      refreshStatus();
    } else {
      bridgeState.classList.add('error');
      bridgeState.lastElementChild.textContent = t('bridge.missing');
      documentObject.querySelectorAll('main button, main textarea, main input').forEach((element) => { element.disabled = true; });
      toast(t('bridge.missing'), 'error');
    }
  }

  initialize();
})(window);
