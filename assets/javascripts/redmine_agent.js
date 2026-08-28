document.addEventListener('DOMContentLoaded', function () {
  var page = document.getElementById('redmine-agent-page');
  if (!page) return;

  var form = document.getElementById('agent-chat-form');
  var input = document.getElementById('agent-chat-input');
  var sendBtn = document.getElementById('agent-chat-send');
  var messages = document.getElementById('agent-chat-messages');
  var newBtn = document.getElementById('agent-new-chat');
  var historyBtn = document.getElementById('agent-history-chat');
  var historyPanel = document.getElementById('agent-history-panel');
  var historyList = document.getElementById('agent-history-list');
  var historyClose = document.getElementById('agent-history-close');
  var clearBtn = document.getElementById('agent-clear-chat');
  var busy = false;
  var chatUrl = page.getAttribute('data-chat-url');
  var historyUrl = page.getAttribute('data-history-url');
  var clearUrl = page.getAttribute('data-clear-url');
  var greeting = page.getAttribute('data-greeting');
  var hitlEnabled = page.getAttribute('data-hitl') === '1';
  var csrfToken = document.querySelector('meta[name="csrf-token"]');

  var i18n = {
    loading: page.getAttribute('data-i18n-loading'),
    historyError: page.getAttribute('data-i18n-history-error'),
    historyEmpty: page.getAttribute('data-i18n-history-empty'),
    deleteTitle: page.getAttribute('data-i18n-delete-title'),
    deleteConfirm: page.getAttribute('data-i18n-delete-confirm'),
    deleteError: page.getAttribute('data-i18n-delete-error'),
    unreachable: page.getAttribute('data-i18n-unreachable'),
    approvalApprove: page.getAttribute('data-i18n-approval-approve'),
    approvalReject: page.getAttribute('data-i18n-approval-reject')
  };

  var currentChatId = null;

  function setHasMessages(state) {
    if (clearBtn) clearBtn.disabled = !state;
  }

  function newChatId() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
      var r = Math.random() * 16 | 0, v = c === 'x' ? r : (r & 0x3 | 0x8);
      return v.toString(16);
    });
  }

  (function initChat() {
    var el = document.getElementById('agent-initial-chat');
    var chat = null;
    if (el) {
      try { chat = JSON.parse(el.textContent); } catch (e) { chat = null; }
    }
    if (chat) {
      loadChat(chat);
    } else {
      currentChatId = newChatId();
    }
  })();

  // ── New chat button ──
  if (newBtn) {
    newBtn.addEventListener('click', function () {
      hideHistoryPanel();
      clearChat();
      currentChatId = newChatId();
      setHasMessages(false);
    });
  }

  // ── History button ──
  if (historyBtn) {
    historyBtn.addEventListener('click', function (e) {
      e.stopPropagation();
      if (historyPanel.hidden) {
        loadHistory();
        historyPanel.hidden = false;
      } else {
        hideHistoryPanel();
      }
    });
  }
  if (historyClose) {
    historyClose.addEventListener('click', hideHistoryPanel);
  }

  // Close the history popup when clicking anywhere outside it.
  document.addEventListener('click', function (e) {
    if (historyPanel.hidden) return;
    if (historyPanel.contains(e.target)) return;
    hideHistoryPanel();
  });

  function hideHistoryPanel() {
    historyPanel.hidden = true;
  }

  function loadHistory() {
    historyList.innerHTML = '';
    historyList.appendChild(emptyRow(i18n.loading));
    fetch(historyUrl, { headers: { 'Accept': 'application/json' } })
      .then(function (res) { return res.json(); })
      .then(function (data) {
        renderHistoryList(data.chats || []);
      })
      .catch(function () {
        historyList.innerHTML = '';
        historyList.appendChild(emptyRow(i18n.historyError));
      });
  }

  function emptyRow(text) {
    var div = document.createElement('div');
    div.className = 'agent-history-empty';
    div.textContent = text;
    return div;
  }

  function renderHistoryList(chats) {
    historyList.innerHTML = '';
    if (!chats.length) {
      historyList.appendChild(emptyRow(i18n.historyEmpty));
      return;
    }
    chats.forEach(function (chat) {
      var row = document.createElement('div');
      row.className = 'agent-history-item';
      if (chat.chat_id === currentChatId) row.className += ' active';

      var body = document.createElement('div');
      body.className = 'agent-history-item-body';
      var preview = document.createElement('div');
      preview.className = 'agent-history-item-request';
      preview.textContent = chat.title;
      var time = document.createElement('div');
      time.className = 'agent-history-item-time';
      time.textContent = new Date(chat.created_at).toLocaleString();
      body.appendChild(preview);
      body.appendChild(time);
      body.addEventListener('click', function () {
        loadChat(chat);
      });

      var del = document.createElement('button');
      del.type = 'button';
      del.className = 'agent-history-item-delete';
      del.title = i18n.deleteTitle;
      del.innerHTML = '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>';
      del.addEventListener('click', function (e) {
        e.stopPropagation();
        if (!window.confirm(i18n.deleteConfirm)) return;
        deleteChat(chat.chat_id, row);
      });

      row.appendChild(body);
      row.appendChild(del);
      historyList.appendChild(row);
    });
  }

  // Delete a single chat from the History popup. Removes its row on
  // success; if it was the one on screen, reset to a fresh chat.
  function deleteChat(chatId, row) {
    fetch(clearUrl, {
      method: 'DELETE',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': csrfToken ? csrfToken.content : ''
      },
      body: JSON.stringify({ chat_id: chatId })
    })
      .then(function (res) { return res.json(); })
      .then(function () {
        if (row && row.parentNode === historyList) historyList.removeChild(row);
        if (chatId === currentChatId) {
          clearChat();
          currentChatId = newChatId();
          setHasMessages(false);
        }
        if (!historyList.children.length) historyList.appendChild(emptyRow(i18n.historyEmpty));
      })
      .catch(function () {
        window.alert(i18n.deleteError);
      });
  }

  function loadChat(chat) {
    hideHistoryPanel();
    messages.innerHTML = '';
    clearWelcome();
    var exchanges = chat.exchanges || [];
    exchanges.forEach(function (ex, index) {
      appendMessage(ex.request, 'user');
      var isLast = (index === exchanges.length - 1);
      renderAgentResponse({ type: 'html', html: ex.html, reply: ex.reply }, isLast);
    });
    currentChatId = chat.chat_id;
    setHasMessages(true);
  }

  // ── Delete (current chat) button ──
  if (clearBtn) {
    clearBtn.addEventListener('click', function () {
      if (clearBtn.disabled) return;
      if (!window.confirm(i18n.deleteConfirm)) return;
      deleteCurrentChat();
    });
  }

  function deleteCurrentChat() {
    fetch(clearUrl, {
      method: 'DELETE',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': csrfToken ? csrfToken.content : ''
      },
      body: JSON.stringify({ chat_id: currentChatId })
    })
      .then(function (res) { return res.json(); })
      .then(function () {
        clearChat();
        currentChatId = newChatId();
        setHasMessages(false);
      })
      .catch(function () {
        appendMessage(i18n.deleteError, 'agent');
      });
  }

  function clearChat() {
    messages.innerHTML = '';
    showWelcome();
  }

  function showWelcome() {
    if (messages.querySelector('.agent-welcome')) return;
    var div = document.createElement('div');
    div.className = 'agent-welcome';

    var icon = document.createElement('div');
    icon.className = 'welcome-icon';
    icon.innerHTML = '<svg viewBox="0 0 24 24" width="40" height="40" fill="currentColor"><path d="M12 2a2 2 0 0 1 2 2c0 .74-.4 1.39-1 1.73V7h1a7 7 0 0 1 7 7h1a1 1 0 0 1 1 1v3a1 1 0 0 1-1 1h-1.07A7.001 7.001 0 0 1 14 23h-4a7.001 7.001 0 0 1-6.93-4H2a1 1 0 0 1-1-1v-3a1 1 0 0 1 1-1h1a7 7 0 0 1 7-7h1V5.73c-.6-.34-1-.99-1-1.73a2 2 0 0 1 2-2zM9 15a1 1 0 1 0 0 2 1 1 0 0 0 0-2zm6 0a1 1 0 1 0 0 2 1 1 0 0 0 0-2z"/></svg>';

    var title = document.createElement('h3');
    title.textContent = page.getAttribute('data-welcome-title');

    var text = document.createElement('p');
    text.textContent = page.getAttribute('data-welcome-text');

    div.appendChild(icon);
    div.appendChild(title);
    div.appendChild(text);
    messages.appendChild(div);
  }

  function clearWelcome() {
    var w = messages.querySelector('.agent-welcome');
    if (w) w.remove();
  }

  function appendMessage(text, sender) {
    clearWelcome();
    var el = document.createElement('div');
    el.className = 'redmine-agent-msg ' + sender;
    el.textContent = text;
    messages.appendChild(el);
    messages.scrollTop = messages.scrollHeight;
  }

  // Marker the server adds when a write tool is paused for approval. Matched
  // loosely so a marker a model wrote itself is stripped from the text too —
  // the buttons follow the server's marker, never the model's wording.
  //
  // The pattern is inlined in both helpers on purpose: initChat() renders the
  // stored chat from the top of this file, before a `var` down here would have
  // been assigned. Function declarations hoist whole, a `var` does not.
  function hasApprovalMarker(text) {
    return (text || '').search(/\[\s*AWAITING_APPROVAL[^\]]*\]/i) !== -1;
  }

  function stripApprovalMarker(text) {
    return (text || '').replace(/\[\s*AWAITING_APPROVAL[^\]]*\]/gi, '');
  }

  function renderAgentResponse(data, isLast) {
    if (isLast === undefined) isLast = true;
    clearWelcome();
    var el = document.createElement('div');
    el.className = 'redmine-agent-msg agent';

    if (data.error) {
      el.textContent = data.error;
    } else if (data.type === 'html' && data.html) {
      // Only the newest reply can still be waiting on a decision, and only
      // while approval is switched on in the plugin settings.
      var hasApproval = isLast && hitlEnabled &&
        (hasApprovalMarker(data.reply) || hasApprovalMarker(data.html));

      // Strip the marker from displayed content
      el.innerHTML = stripApprovalMarker(data.html);

      if (hasApproval) {
        el.classList.add('approval-pending');
        appendApprovalButtons(el);
      }
    } else {
      el.textContent = stripApprovalMarker(data.reply).trim();
    }

    messages.appendChild(el);
    messages.scrollTop = messages.scrollHeight;
  }

  // ── HITL: Append Approve / Reject buttons to a message ──
  // Only Approve runs the action; Reject just cancels it server-side.
  function appendApprovalButtons(el) {
    var actions = document.createElement('div');
    actions.className = 'approval-actions';

    var approveBtn = document.createElement('button');
    approveBtn.type = 'button';
    approveBtn.className = 'approval-btn approve';
    approveBtn.innerHTML = '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg> ' + i18n.approvalApprove;

    var rejectBtn = document.createElement('button');
    rejectBtn.type = 'button';
    rejectBtn.className = 'approval-btn reject';
    rejectBtn.innerHTML = '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg> ' + i18n.approvalReject;

    actions.appendChild(approveBtn);
    actions.appendChild(rejectBtn);
    el.appendChild(actions);

    // Click Approve → send the approval word; the server then runs the action.
    approveBtn.addEventListener('click', function () {
      disableApprovalButtons(actions, 'approved');
      appendMessage(i18n.approvalApprove, 'user');
      sendMessage(i18n.approvalApprove);
    });

    // Click Reject → send the reject word; the server cancels without running.
    rejectBtn.addEventListener('click', function () {
      disableApprovalButtons(actions, 'rejected');
      appendMessage(i18n.approvalReject, 'user');
      sendMessage(i18n.approvalReject);
    });
  }

  function disableApprovalButtons(actionsEl, decision) {
    actionsEl.innerHTML = '';
    var badge = document.createElement('div');
    badge.className = 'approval-badge ' + decision;
    if (decision === 'approved') {
      badge.innerHTML = '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg> ' + i18n.approvalApprove;
    } else {
      badge.innerHTML = '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg> ' + i18n.approvalReject;
    }
    actionsEl.appendChild(badge);
  }

  var loadingEl = null;
  function showLoading() {
    if (loadingEl) return;
    loadingEl = document.createElement('div');
    loadingEl.className = 'redmine-agent-msg agent loading';
    loadingEl.innerHTML = '<span class="dot"></span><span class="dot"></span><span class="dot"></span>';
    messages.appendChild(loadingEl);
    messages.scrollTop = messages.scrollHeight;
  }

  function hideLoading() {
    if (loadingEl && loadingEl.parentNode === messages) {
      messages.removeChild(loadingEl);
      loadingEl = null;
    }
  }

  function updateSendButton() {
    if (sendBtn) sendBtn.disabled = busy || input.value.trim() === '';
  }

  function setBusy(state) {
    busy = state;
    updateSendButton();
  }

  function sendMessage(text) {
    if (!currentChatId) currentChatId = newChatId();
    setBusy(true);
    showLoading();
    fetch(chatUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': csrfToken ? csrfToken.content : ''
      },
      body: JSON.stringify({ message: text, chat_id: currentChatId })
    })
      .then(function (res) { return res.json(); })
      .then(function (data) {
        hideLoading();
        renderAgentResponse(data);
        if (data && data.chat_id) currentChatId = data.chat_id;
        if (data && !data.error) setHasMessages(true);
      })
      .catch(function () {
        hideLoading();
        appendMessage(i18n.unreachable, 'agent');
      })
      .then(function () { setBusy(false); });
  }

  // Grow the textarea with its content, up to a capped height (then scroll).
  function autoGrowInput() {
    input.style.height = 'auto';
    input.style.height = Math.min(input.scrollHeight, 160) + 'px';
  }

  input.addEventListener('input', function () {
    updateSendButton();
    autoGrowInput();
  });

  // Enter submits; Shift+Enter (or Ctrl/Cmd+Enter) inserts a newline.
  input.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && !e.shiftKey && !e.ctrlKey && !e.metaKey && !e.isComposing) {
      e.preventDefault();
      if (typeof form.requestSubmit === 'function') {
        form.requestSubmit();
      } else {
        form.dispatchEvent(new Event('submit', { cancelable: true }));
      }
    }
  });

  form.addEventListener('submit', function (e) {
    e.preventDefault();
    if (busy) return;
    var text = input.value.trim();
    if (!text) return;
    appendMessage(text, 'user');
    input.value = '';
    updateSendButton();
    autoGrowInput();
    sendMessage(text);
  });

  updateSendButton();

  // ── Agent management (admin only) ──
  var customAgentsUrl = page.getAttribute('data-custom-agents-url');
  if (!customAgentsUrl) return;

  var manageBtn = document.getElementById('agent-manage-agents');
  var agentsPanel = document.getElementById('agent-agents-panel');
  var agentsList = document.getElementById('agent-agents-list');
  var agentsClose = document.getElementById('agent-agents-close');
  var newAgentBtn = document.getElementById('agent-new-agent-btn');
  var addAgentBtn = document.getElementById('agent-add-agent');

  var ai18n = {
    agentsTitle: page.getAttribute('data-i18n-agents-title'),
    noAgents: page.getAttribute('data-i18n-no-agents'),
    editAgent: page.getAttribute('data-i18n-edit-agent'),
    addAgent: page.getAttribute('data-i18n-add-agent'),
    agentName: page.getAttribute('data-i18n-agent-name'),
    agentTask: page.getAttribute('data-i18n-agent-task'),
    agentTaskHint: page.getAttribute('data-i18n-agent-task-hint'),
    agentSchedule: page.getAttribute('data-i18n-agent-schedule'),
    freqLabel: page.getAttribute('data-i18n-schedule-frequency'),
    freqDaily: page.getAttribute('data-i18n-schedule-daily'),
    freqWeekdays: page.getAttribute('data-i18n-schedule-weekdays'),
    freqWeekly: page.getAttribute('data-i18n-schedule-weekly'),
    freqMonthly: page.getAttribute('data-i18n-schedule-monthly'),
    timeLabel: page.getAttribute('data-i18n-schedule-time'),
    weekdayLabel: page.getAttribute('data-i18n-schedule-weekday'),
    dayLabel: page.getAttribute('data-i18n-schedule-day'),
    notify: page.getAttribute('data-i18n-notify'),
    notifySlack: page.getAttribute('data-i18n-notify-slack'),
    notifyEmail: page.getAttribute('data-i18n-notify-email'),
    notifyTeams: page.getAttribute('data-i18n-notify-teams'),
    notifyJira: page.getAttribute('data-i18n-notify-jira'),
    comingSoon: page.getAttribute('data-i18n-notify-coming-soon'),
    slackChannel: page.getAttribute('data-i18n-slack-channel'),
    slackChannelHint: page.getAttribute('data-i18n-slack-channel-hint'),
    save: page.getAttribute('data-i18n-save'),
    saving: page.getAttribute('data-i18n-saving'),
    saveFailed: page.getAttribute('data-i18n-save-failed'),
    cancel: page.getAttribute('data-i18n-cancel'),
    deleteAgentConfirm: page.getAttribute('data-i18n-delete-agent-confirm'),
    runNow: page.getAttribute('data-i18n-run-now'),
    running: page.getAttribute('data-i18n-running'),
    neverRun: page.getAttribute('data-i18n-never-run')
  };

  function jsonHeaders() {
    return { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken ? csrfToken.content : '' };
  }

  function hideAgentsPanel() {
    if (agentsPanel) agentsPanel.hidden = true;
  }

  if (manageBtn) {
    manageBtn.addEventListener('click', function (e) {
      e.stopPropagation();
      if (agentsPanel.hidden) {
        loadAgentsList();
        agentsPanel.hidden = false;
      } else {
        hideAgentsPanel();
      }
    });
  }
  if (agentsClose) agentsClose.addEventListener('click', hideAgentsPanel);

  document.addEventListener('click', function (e) {
    if (!agentsPanel || agentsPanel.hidden) return;
    if (agentsPanel.contains(e.target) || (manageBtn && manageBtn.contains(e.target))) return;
    hideAgentsPanel();
  });

  function loadAgentsList() {
    agentsList.innerHTML = '';
    agentsList.appendChild(emptyRow(i18n.loading));
    fetch(customAgentsUrl, { headers: { 'Accept': 'application/json' } })
      .then(function (res) { return res.json(); })
      .then(function (data) { renderAgentsList(data.agents || []); })
      .catch(function () {
        agentsList.innerHTML = '';
        agentsList.appendChild(emptyRow(i18n.historyError));
      });
  }

  function renderAgentsList(agents) {
    agentsList.innerHTML = '';
    if (!agents.length) {
      agentsList.appendChild(emptyRow(ai18n.noAgents));
      return;
    }
    agents.forEach(function (agent) { agentsList.appendChild(buildAgentRow(agent)); });
  }

  function buildAgentRow(agent) {
    var row = document.createElement('div');
    row.className = 'agent-history-item agent-agent-item';

    var body = document.createElement('div');
    body.className = 'agent-history-item-body';

    var name = document.createElement('div');
    name.className = 'agent-history-item-request';
    name.textContent = agent.name + (agent.enabled === false ? ' (disabled)' : '');

    var meta = document.createElement('div');
    meta.className = 'agent-history-item-time';
    var bits = [];
    if (agent.cron) bits.push(agent.next_run ? new Date(agent.next_run).toLocaleString() : ai18n.runNow);
    var notifyBits = [];
    if (agent.notify && agent.notify.slack) notifyBits.push(ai18n.notifySlack);
    if (agent.notify && agent.notify.email) notifyBits.push(ai18n.notifyEmail);
    if (notifyBits.length) bits.push(notifyBits.join(', '));
    meta.textContent = bits.join(' · ');

    body.appendChild(name);
    body.appendChild(meta);
    body.addEventListener('click', function () { openAgentForm(agent); });

    var actions = document.createElement('div');
    actions.className = 'agent-agent-actions';

    var editBtn = document.createElement('button');
    editBtn.type = 'button';
    editBtn.className = 'agent-agent-action-btn';
    editBtn.textContent = ai18n.editAgent;
    editBtn.addEventListener('click', function (e) { e.stopPropagation(); openAgentForm(agent); });
    actions.appendChild(editBtn);

    if (agent.cron) {
      var runBtn = document.createElement('button');
      runBtn.type = 'button';
      runBtn.className = 'agent-agent-action-btn';
      runBtn.textContent = ai18n.runNow;
      runBtn.addEventListener('click', function (e) {
        e.stopPropagation();
        runBtn.disabled = true;
        runBtn.textContent = ai18n.running;
        fetch(customAgentsUrl + '/' + agent.key + '/run', { method: 'POST', headers: jsonHeaders() })
          .then(function (r) { return r.json(); })
          .then(function () { runBtn.disabled = false; runBtn.textContent = ai18n.runNow; })
          .catch(function () { runBtn.disabled = false; runBtn.textContent = ai18n.runNow; });
      });
      actions.appendChild(runBtn);
    }

    if (agent.deletable) {
      var delBtn = document.createElement('button');
      delBtn.type = 'button';
      delBtn.className = 'agent-history-item-delete';
      delBtn.title = i18n.deleteTitle;
      delBtn.innerHTML = '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>';
      delBtn.addEventListener('click', function (e) {
        e.stopPropagation();
        if (!window.confirm(ai18n.deleteAgentConfirm)) return;
        fetch(customAgentsUrl + '/' + agent.key, { method: 'DELETE', headers: jsonHeaders() })
          .then(function (r) { return r.json(); })
          .then(function () {
            row.remove();
            removeAgentMenuItem(agent.key);
            if (!agentsList.children.length) agentsList.appendChild(emptyRow(ai18n.noAgents));
          });
      });
      actions.appendChild(delBtn);
    }

    row.appendChild(body);
    row.appendChild(actions);
    return row;
  }

  function agentMenuList() {
    var link = document.querySelector('#main-menu a[href*="/redmine_agent"]');
    return link ? link.closest('ul') : null;
  }

  function applyAgentMenuEntry(menu) {
    if (!menu) return;
    var ul = agentMenuList();
    if (!ul) return;
    var existing = ul.querySelector('a[href="' + menu.url + '"]');
    if (existing) { existing.textContent = menu.name; return; }
    var li = document.createElement('li');
    var a = document.createElement('a');
    a.href = menu.url;
    a.className = 'ai-agent-' + menu.key;
    a.textContent = menu.name;
    li.appendChild(a);
    ul.appendChild(li);
  }

  function removeAgentMenuItem(key) {
    var ul = agentMenuList();
    if (!ul) return;
    var a = ul.querySelector('a[href*="agent_key=' + key + '"]');
    if (a) {
      var li = a.closest('li');
      if (li) li.remove();
    }
  }

  // ── Create / edit form (modal) ──
  function labeled(label, field) {
    var wrap = document.createElement('div');
    wrap.className = 'agent-form-field';
    wrap.appendChild(label);
    wrap.appendChild(field);
    return wrap;
  }

  function textLabel(text) {
    var l = document.createElement('label');
    l.textContent = text;
    return l;
  }

  function notifyCheckbox(labelText, checked, disabled) {
    var wrap = document.createElement('label');
    wrap.className = 'agent-notify-check' + (disabled ? ' disabled' : '');
    var input = document.createElement('input');
    input.type = 'checkbox';
    input.checked = !!checked;
    input.disabled = !!disabled;
    wrap.appendChild(input);
    wrap.appendChild(document.createTextNode(' ' + labelText));
    return { wrap: wrap, input: input };
  }

  function parseCronForForm(cron) {
    if (!cron) return { frequency: 'none', time: '09:00', weekday: '0', day: '1', timezone: 'Asia/Kolkata' };
    var parts = cron.trim().split(/\s+/);
    var min = parts[0], hour = parts[1], dom = parts[2], dow = parts[4], tz = parts[5] || 'Asia/Kolkata';
    var time = (hour.length < 2 ? '0' + hour : hour) + ':' + (min.length < 2 ? '0' + min : min);
    var frequency = 'daily', weekday = '0', day = '1';
    if (dow === '1-5') { frequency = 'weekdays'; }
    else if (dow !== '*') { frequency = 'weekly'; weekday = dow; }
    else if (dom !== '*') { frequency = 'monthly'; day = dom; }
    return { frequency: frequency, time: time, weekday: weekday, day: day, timezone: tz };
  }

  function ensureAgentModal() {
    var modal = document.getElementById('agent-form-modal');
    if (modal) return modal;
    modal = document.createElement('div');
    modal.id = 'agent-form-modal';
    modal.className = 'agent-modal-backdrop';
    modal.hidden = true;
    document.body.appendChild(modal);
    modal.addEventListener('click', function (e) { if (e.target === modal) closeAgentForm(); });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && !modal.hidden) closeAgentForm();
    });
    return modal;
  }

  function closeAgentForm() {
    var modal = document.getElementById('agent-form-modal');
    if (modal) modal.hidden = true;
  }

  function openAgentForm(agent) {
    var modal = ensureAgentModal();
    var isEdit = !!(agent && agent.key);
    var initial = agent || {};
    var sched = parseCronForForm(initial.cron);

    modal.innerHTML = '';
    var box = document.createElement('div');
    box.className = 'agent-modal';

    var title = document.createElement('h3');
    title.textContent = isEdit ? ai18n.editAgent : ai18n.addAgent;
    box.appendChild(title);

    var form = document.createElement('div');
    form.className = 'agent-form';

    var nameInput = document.createElement('input');
    nameInput.type = 'text';
    nameInput.value = initial.name || '';
    form.appendChild(labeled(textLabel(ai18n.agentName), nameInput));

    var taskInput = document.createElement('textarea');
    taskInput.rows = 6;
    taskInput.value = initial.task || '';
    form.appendChild(labeled(textLabel(ai18n.agentTask), taskInput));

    var taskHint = document.createElement('p');
    taskHint.className = 'agent-form-hint';
    taskHint.textContent = ai18n.agentTaskHint;
    form.appendChild(taskHint);

    var schedWrap = document.createElement('div');
    schedWrap.className = 'agent-form-field agent-sched-toggle';
    var schedCheck = document.createElement('input');
    schedCheck.type = 'checkbox';
    schedCheck.id = 'agent-form-sched-on';
    schedCheck.checked = sched.frequency !== 'none';
    var schedCheckLabel = document.createElement('label');
    schedCheckLabel.htmlFor = 'agent-form-sched-on';
    schedCheckLabel.textContent = ai18n.agentSchedule;
    schedWrap.appendChild(schedCheck);
    schedWrap.appendChild(schedCheckLabel);
    form.appendChild(schedWrap);

    var schedFields = document.createElement('div');
    schedFields.className = 'agent-sched-fields';

    var freqSelect = document.createElement('select');
    freqSelect.className = 'multi-row';
    [['daily', ai18n.freqDaily], ['weekdays', ai18n.freqWeekdays], ['weekly', ai18n.freqWeekly], ['monthly', ai18n.freqMonthly]]
      .forEach(function (pair) {
        var opt = document.createElement('option');
        opt.value = pair[0];
        opt.textContent = pair[1];
        if (sched.frequency === pair[0]) opt.selected = true;
        freqSelect.appendChild(opt);
      });
    schedFields.appendChild(labeled(textLabel(ai18n.freqLabel), freqSelect));

    var timeInput = document.createElement('input');
    timeInput.type = 'time';
    timeInput.value = sched.time;
    schedFields.appendChild(labeled(textLabel(ai18n.timeLabel), timeInput));

    var weekdaySelect = document.createElement('select');
    weekdaySelect.className = 'multi-row';
    ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'].forEach(function (d, i) {
      var opt = document.createElement('option');
      opt.value = i;
      opt.textContent = d;
      if (String(sched.weekday) === String(i)) opt.selected = true;
      weekdaySelect.appendChild(opt);
    });
    var weekdayRow = labeled(textLabel(ai18n.weekdayLabel), weekdaySelect);
    schedFields.appendChild(weekdayRow);

    var dayInput = document.createElement('input');
    dayInput.type = 'number';
    dayInput.min = 1;
    dayInput.max = 31;
    dayInput.value = sched.day;
    var dayRow = labeled(textLabel(ai18n.dayLabel), dayInput);
    schedFields.appendChild(dayRow);

    form.appendChild(schedFields);

    function syncSchedVisibility() {
      schedFields.hidden = !schedCheck.checked;
      weekdayRow.hidden = freqSelect.value !== 'weekly';
      dayRow.hidden = freqSelect.value !== 'monthly';
    }
    schedCheck.addEventListener('change', syncSchedVisibility);
    freqSelect.addEventListener('change', syncSchedVisibility);
    syncSchedVisibility();

    var notifyLabel = document.createElement('div');
    notifyLabel.className = 'agent-form-section-label';
    notifyLabel.textContent = ai18n.notify;
    form.appendChild(notifyLabel);

    var notifyRow = document.createElement('div');
    notifyRow.className = 'agent-notify-row';
    var slackCheck = notifyCheckbox(ai18n.notifySlack, initial.notify && initial.notify.slack, false);
    var emailCheck = notifyCheckbox(ai18n.notifyEmail, initial.notify && initial.notify.email, false);
    var teamsCheck = notifyCheckbox(ai18n.notifyTeams + ' ' + ai18n.comingSoon, false, true);
    var jiraCheck = notifyCheckbox(ai18n.notifyJira + ' ' + ai18n.comingSoon, false, true);
    [slackCheck, emailCheck, teamsCheck, jiraCheck].forEach(function (c) { notifyRow.appendChild(c.wrap); });
    form.appendChild(notifyRow);

    // Channel is asked for only once Slack is ticked; blank means DM each
    // person instead of posting to a channel.
    var channelInput = document.createElement('input');
    channelInput.type = 'text';
    channelInput.placeholder = '#reminders';
    channelInput.value = initial.slack_channel || '';
    var channelRow = labeled(textLabel(ai18n.slackChannel), channelInput);
    channelRow.classList.add('agent-slack-channel');

    var channelHint = document.createElement('p');
    channelHint.className = 'agent-form-hint';
    channelHint.textContent = ai18n.slackChannelHint;
    channelRow.appendChild(channelHint);
    form.appendChild(channelRow);

    function syncChannelVisibility() {
      channelRow.hidden = !slackCheck.input.checked;
    }
    slackCheck.input.addEventListener('change', syncChannelVisibility);
    syncChannelVisibility();

    box.appendChild(form);

    var errorMsg = document.createElement('div');
    errorMsg.className = 'agent-form-error';
    box.appendChild(errorMsg);

    var actions = document.createElement('div');
    actions.className = 'agent-form-actions';

    var cancelBtn = document.createElement('button');
    cancelBtn.type = 'button';
    cancelBtn.textContent = ai18n.cancel;
    cancelBtn.addEventListener('click', closeAgentForm);

    var saveBtn = document.createElement('button');
    saveBtn.type = 'button';
    saveBtn.className = 'primary';
    saveBtn.textContent = ai18n.save;
    saveBtn.addEventListener('click', function () {
      var name = nameInput.value.trim();
      var task = taskInput.value.trim();
      errorMsg.textContent = '';
      if (!name || !task) { errorMsg.textContent = ai18n.saveFailed; return; }
      if (schedCheck.checked && !timeInput.value) { errorMsg.textContent = ai18n.saveFailed; return; }

      var payload = {
        name: name,
        task: task,
        notify: { slack: slackCheck.input.checked, email: emailCheck.input.checked },
        slack_channel: slackCheck.input.checked ? channelInput.value.trim() : ''
      };
      if (schedCheck.checked) {
        payload.frequency = freqSelect.value;
        payload.time = timeInput.value;
        payload.weekday = weekdaySelect.value;
        payload.day = dayInput.value;
      } else {
        payload.frequency = 'none';
      }

      saveBtn.disabled = true;
      errorMsg.textContent = ai18n.saving;
      var url = isEdit ? (customAgentsUrl + '/' + initial.key) : customAgentsUrl;
      var method = isEdit ? 'PATCH' : 'POST';
      fetch(url, { method: method, headers: jsonHeaders(), body: JSON.stringify(payload) })
        .then(function (res) { return res.json().then(function (data) { return { ok: res.ok, data: data }; }); })
        .then(function (res) {
          saveBtn.disabled = false;
          if (!res.ok || res.data.error) {
            errorMsg.textContent = (res.data && res.data.error) || ai18n.saveFailed;
            return;
          }
          errorMsg.textContent = '';
          closeAgentForm();
          applyAgentMenuEntry(res.data.menu);
          if (agentsPanel && !agentsPanel.hidden) loadAgentsList();
        })
        .catch(function () {
          saveBtn.disabled = false;
          errorMsg.textContent = ai18n.saveFailed;
        });
    });

    actions.appendChild(cancelBtn);
    actions.appendChild(saveBtn);
    box.appendChild(actions);

    modal.appendChild(box);
    modal.hidden = false;
  }

  if (newAgentBtn) newAgentBtn.addEventListener('click', function () { openAgentForm(null); });
  if (addAgentBtn) addAgentBtn.addEventListener('click', function () { openAgentForm(null); });
});
