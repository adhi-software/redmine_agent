document.addEventListener('DOMContentLoaded', function () {
  var page = document.getElementById('redmine-agent-page');
  if (!page) return;

  var form = document.getElementById('agent-chat-form');
  var input = document.getElementById('agent-chat-input');
  var sendBtn = document.getElementById('agent-chat-send');
  var messages = document.getElementById('agent-chat-messages');
  var chatArea = document.getElementById('agent-chat-area');
  var newBtn = document.getElementById('agent-new-chat');
  var historyBtn = document.getElementById('agent-history-chat');
  var historyPanel = document.getElementById('agent-history-panel');
  var historyList = document.getElementById('agent-history-list');
  var historyClose = document.getElementById('agent-history-close');
  var clearBtn = document.getElementById('agent-clear-chat');
  // Set on a scheduled agent's page, blank on the Query Agent's. A scheduled
  // agent's page shows its whole history and has no chat buttons at all.
  var currentAgentKey = page.getAttribute('data-current-agent-key') || '';
  var busy = false;
  var chatUrl = page.getAttribute('data-chat-url');
  var historyUrl = page.getAttribute('data-history-url');
  var clearUrl = page.getAttribute('data-clear-url');
  var hitlEnabled = page.getAttribute('data-hitl') === '1';
  var csrfToken = document.querySelector('meta[name="csrf-token"]');

  var i18n = {
    loading: page.getAttribute('data-i18n-loading'),
    historyError: page.getAttribute('data-i18n-history-error'),
    historyEmpty: page.getAttribute('data-i18n-history-empty'),
    deleteTitle: page.getAttribute('data-i18n-delete-title'),
    deleteConfirm: page.getAttribute('data-i18n-delete-confirm'),
    deleteError: page.getAttribute('data-i18n-delete-error'),
    clearConfirm: page.getAttribute('data-i18n-clear-confirm'),
    unreachable: page.getAttribute('data-i18n-unreachable'),
    approvalApprove: page.getAttribute('data-i18n-approval-approve'),
    approvalReject: page.getAttribute('data-i18n-approval-reject'),
    runFailed: page.getAttribute('data-i18n-run-failed')
  };

  var currentChatId = null;

  function setHasMessages(state) {
    if (clearBtn) clearBtn.disabled = !state;
  }

  // Empty chat: CSS floats the composer to the middle of the area.
  function setComposerCentered(on) {
    if (form && chatArea) chatArea.classList.toggle('agent-chat-empty', on);
  }

  function newChatId() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
      var r = Math.random() * 16 | 0, v = c === 'x' ? r : (r & 0x3 | 0x8);
      return v.toString(16);
    });
  }

  (function initTimeline() {
    var el = document.getElementById('agent-initial-chats');
    var data = null;
    if (el) {
      try { data = JSON.parse(el.textContent); } catch (e) { data = null; }
    }
    loadTimeline(data || {});
  })();

  // Everything this page has to show, oldest at the top: one block per chat,
  // plus the runs that failed before reaching the chat. Typing continues the
  // newest chat, as it always has.
  function loadTimeline(data) {
    var chats = data.chats || [];
    var last = chats[chats.length - 1] || null;
    var entries = chats.map(function (chat) { return { at: chat.created_at, chat: chat }; })
      .concat((data.failed_runs || []).map(function (run) { return { at: run.at, run: run }; }));
    // ISO 8601 stamps, so a plain string compare is chronological.
    entries.sort(function (a, b) { return String(a.at).localeCompare(String(b.at)); });

    messages.innerHTML = '';
    entries.forEach(function (entry) {
      messages.appendChild(entry.chat ? buildChatBlock(entry.chat, entry.chat === last)
                                      : buildRunErrorBlock(entry.run));
    });

    currentChatId = last ? last.chat_id : newChatId();
    // A scheduled agent's clear takes the whole page, failed runs included.
    setHasMessages(currentAgentKey ? entries.length > 0 : !!last);
    if (!entries.length) showWelcome();
    messages.scrollTop = messages.scrollHeight;
  }

  // isCurrent: only the newest chat's last reply can still be awaiting approval.
  function buildChatBlock(chat, isCurrent) {
    var block = document.createElement('div');
    block.className = 'agent-chat-block';
    if (currentAgentKey) block.appendChild(runSeparator(chat.created_at));

    var exchanges = chat.exchanges || [];
    exchanges.forEach(function (ex, index) {
      appendMessage(ex.request, 'user', block);
      renderAgentResponse({ type: 'html', html: ex.html, reply: ex.reply },
                          isCurrent && index === exchanges.length - 1, block);
    });
    return block;
  }

  // Every scheduled run is a chat of its own, so the page marks where each one
  // starts. Clearing is all-or-nothing, from the header.
  function runSeparator(at) {
    var sep = document.createElement('div');
    sep.className = 'agent-run-sep';

    var label = document.createElement('span');
    label.className = 'agent-run-sep-label';
    label.textContent = at ? shortStamp(at) : '';
    sep.appendChild(label);
    return sep;
  }

  // A run that failed never said anything, so its entry is just the reason.
  function buildRunErrorBlock(run) {
    var block = document.createElement('div');
    block.className = 'agent-chat-block';
    block.appendChild(runSeparator(run.at));

    var line = document.createElement('div');
    line.className = 'agent-run-error';
    line.textContent = i18n.runFailed + (run.error ? ': ' + run.error : '');
    block.appendChild(line);
    return block;
  }

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
    if (!historyPanel || historyPanel.hidden) return;
    if (historyPanel.contains(e.target)) return;
    hideHistoryPanel();
  });

  function hideHistoryPanel() {
    if (historyPanel) historyPanel.hidden = true;
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
    setComposerCentered(false);
    messages.innerHTML = '';
    messages.appendChild(buildChatBlock(chat, true));
    currentChatId = chat.chat_id;
    setHasMessages(true);
  }

  // ── Delete button: one chat here, a scheduled agent's whole log there ──
  if (clearBtn) {
    clearBtn.addEventListener('click', function () {
      if (clearBtn.disabled) return;
      if (!window.confirm(currentAgentKey ? i18n.clearConfirm : i18n.deleteConfirm)) return;
      if (currentAgentKey) clearAllChats(); else deleteCurrentChat();
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

  // Wipes this agent's whole history — every chat and its run log.
  function clearAllChats() {
    fetch(clearUrl, {
      method: 'DELETE',
      headers: jsonHeaders(),
      body: JSON.stringify({ all: '1' })
    })
      .then(function (res) { return res.json(); })
      .then(function () {
        clearChat();
        currentChatId = newChatId();
        setHasMessages(false);
      })
      .catch(function () {
        window.alert(i18n.deleteError);
      });
  }

  function clearChat() {
    messages.innerHTML = '';
    showWelcome();
  }

  function showWelcome() {
    setComposerCentered(true);
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
    setComposerCentered(false);
    var w = messages.querySelector('.agent-welcome');
    if (w) w.remove();
  }

  function appendMessage(text, sender, target) {
    clearWelcome();
    var el = document.createElement('div');
    el.className = 'redmine-agent-msg ' + sender;
    el.textContent = text;
    (target || messages).appendChild(el);
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

  function renderAgentResponse(data, isLast, target) {
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

    (target || messages).appendChild(el);
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
    if (sendBtn && input) sendBtn.disabled = busy || input.value.trim() === '';
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

  // A scheduled agent's page renders no composer, so there is nothing to wire.
  if (input && form) {
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
  }

  // ── Agent management (your own agents) ──
  var customAgentsUrl = page.getAttribute('data-custom-agents-url');
  if (!customAgentsUrl) return;

  var editAgentBtn = document.getElementById('agent-edit-agent');
  // A run is over in seconds normally; the cap covers the runner's own timeout.
  var RUN_POLL_MS  = 2000;
  var RUN_POLL_MAX = 155;

  var runAgentBtn = document.getElementById('agent-run-agent');
  var deleteAgentBtn = document.getElementById('agent-delete-agent');
  var addAgentBtn = document.getElementById('agent-add-agent');

  var ai18n = {
    editAgent: page.getAttribute('data-i18n-edit-agent'),
    addAgent: page.getAttribute('data-i18n-add-agent'),
    agentName: page.getAttribute('data-i18n-agent-name'),
    agentTask: page.getAttribute('data-i18n-agent-task'),
    agentTaskHint: page.getAttribute('data-i18n-agent-task-hint'),
    notifyChannels: page.getAttribute('data-notify-channels'),
    agentSchedule: page.getAttribute('data-i18n-agent-schedule'),
    freqLabel: page.getAttribute('data-i18n-schedule-frequency'),
    freqNone: page.getAttribute('data-i18n-schedule-none'),
    freqHourly: page.getAttribute('data-i18n-schedule-hourly'),
    everyLabel: page.getAttribute('data-i18n-schedule-every'),
    hoursLabel: page.getAttribute('data-i18n-schedule-hours'),
    freqDaily: page.getAttribute('data-i18n-schedule-daily'),
    freqWeekdays: page.getAttribute('data-i18n-schedule-weekdays'),
    freqWeekly: page.getAttribute('data-i18n-schedule-weekly'),
    freqMonthly: page.getAttribute('data-i18n-schedule-monthly'),
    timeLabel: page.getAttribute('data-i18n-schedule-time'),
    weekdayLabel: page.getAttribute('data-i18n-schedule-weekday'),
    dayLabel: page.getAttribute('data-i18n-schedule-day'),
    lastDay: page.getAttribute('data-i18n-schedule-last-day'),
    dayWarning: page.getAttribute('data-i18n-schedule-day-warning'),
    save: page.getAttribute('data-i18n-save'),
    saving: page.getAttribute('data-i18n-saving'),
    saveFailed: page.getAttribute('data-i18n-save-failed'),
    cancel: page.getAttribute('data-i18n-cancel'),
    deleteAgentConfirm: page.getAttribute('data-i18n-delete-agent-confirm'),
    deleteAgent: page.getAttribute('data-i18n-delete-agent'),
    clearLog: page.getAttribute('data-i18n-clear-log'),
    runNow: page.getAttribute('data-i18n-run-now'),
    running: page.getAttribute('data-i18n-running'),
    timezone: page.getAttribute('data-i18n-schedule-timezone'),
    dayNames: (page.getAttribute('data-i18n-day-names') || '').split(','),
    errNameBlank: page.getAttribute('data-i18n-error-name-blank'),
    errTaskBlank: page.getAttribute('data-i18n-error-task-blank'),
    errSchedule: page.getAttribute('data-i18n-error-schedule')
  };

  // Zone new schedules are saved in; existing ones keep whatever their cron has.
  var defaultTimezone = page.getAttribute('data-agent-timezone') || '';

  function jsonHeaders() {
    return { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken ? csrfToken.content : '' };
  }

  // Fetched fresh so the form always opens on what is stored.
  function withAgent(key, callback) {
    fetch(customAgentsUrl, { headers: { 'Accept': 'application/json' } })
      .then(function (res) { return res.json(); })
      .then(function (data) {
        var agent = (data.agents || []).filter(function (a) { return a.key === key; })[0];
        if (agent) callback(agent);
      });
  }

  if (editAgentBtn) {
    editAgentBtn.addEventListener('click', function () { withAgent(currentAgentKey, openAgentForm); });
  }

  // Every agent can be run on demand - a schedule is not what makes it runnable.
  if (runAgentBtn) {
    runAgentBtn.addEventListener('click', function () {
      runAgentBtn.disabled = true;
      runAgentBtn.title = ai18n.running;
      fetch(customAgentsUrl + '/' + currentAgentKey + '/run', { method: 'POST', headers: jsonHeaders() })
        .then(function (res) { return res.json(); })
        .then(function (data) {
          if (!data || !data.run_id) throw new Error('run not started');
          pollRun(currentAgentKey, data.run_id, 0, function () { window.location.reload(); });
        })
        .catch(function () {
          runAgentBtn.disabled = false;
          runAgentBtn.title = ai18n.runNow;
        });
    });
  }

  // The run happens in the background, so the caller waits for its log row to
  // leave 'started' before showing what it wrote.
  function pollRun(key, runId, attempt, done) {
    if (attempt >= RUN_POLL_MAX) { done(); return; }

    window.setTimeout(function () {
      fetch(customAgentsUrl + '/' + key + '/runs', { headers: jsonHeaders() })
        .then(function (res) { return res.json(); })
        .then(function (data) {
          var match = (data.runs || []).filter(function (run) { return run.id === runId; })[0];
          if (match && match.status !== 'started') { done(); return; }
          pollRun(key, runId, attempt + 1, done);
        })
        .catch(function () { done(); });
    }, RUN_POLL_MS);
  }

  if (deleteAgentBtn) {
    deleteAgentBtn.addEventListener('click', function () {
      if (!window.confirm(ai18n.deleteAgentConfirm)) return;
      fetch(customAgentsUrl + '/' + currentAgentKey, { method: 'DELETE', headers: jsonHeaders() })
        .then(function (r) { return r.json(); })
        // This page goes with the agent; the bare URL is the Query Agent's.
        .then(function () { window.location.href = window.location.pathname; });
    });
  }

  // Seconds are noise on a run separator.
  function shortStamp(value) {
    return new Date(value).toLocaleString([], { dateStyle: 'short', timeStyle: 'short' });
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
    // The theme only decorates menu links once, on load, so borrow a sibling's
    // icon rather than leaving this row bare until the next page load.
    var icon = ul.querySelector('li > svg');
    if (icon) li.appendChild(icon.cloneNode(true));
    li.appendChild(a);
    ul.appendChild(li);
    decorateAgentMenuRows();
  }

  // ── Per-agent actions on the left-nav rows ──
  // The header's actions, reachable on any of your agents without opening it.
  // The shared Chat agent is not one you manage, so its row gets none.
  var ROW_ACTIONS = [
    { action: 'edit',   title: ai18n.editAgent },
    { action: 'run',    title: ai18n.runNow },
    { action: 'clear',  title: ai18n.clearLog,    cls: 'danger' },
    { action: 'delete', title: ai18n.deleteAgent, cls: 'danger' }
  ];

  function agentKeyFromHref(href) {
    var match = /[?&]agent_key=([^&]+)/.exec(href || '');
    return match ? decodeURIComponent(match[1]) : '';
  }

  function decorateAgentMenuRows() {
    var ul = agentMenuList();
    if (!ul) return;
    Array.prototype.forEach.call(ul.querySelectorAll('a[href*="agent_key="]'), function (link) {
      var key = agentKeyFromHref(link.getAttribute('href'));
      var li = link.closest('li');
      if (!key || key === 'query' || !li || li.classList.contains('agent-row')) return;
      li.classList.add('agent-row');

      var box = document.createElement('span');
      box.className = 'agent-row-actions';
      box.setAttribute('data-agent-key', key);
      ROW_ACTIONS.forEach(function (spec) {
        var btn = document.createElement('button');
        btn.type = 'button';
        btn.title = spec.title || '';
        // Icon comes from CSS: an svg here would make the theme's icon pass
        // treat the row as already decorated and skip its own menu icon.
        btn.className = 'act-' + spec.action + (spec.cls ? ' ' + spec.cls : '');
        btn.setAttribute('data-agent-action', spec.action);
        box.appendChild(btn);
      });
      li.appendChild(box);
    });
  }

  // Delegated: rows come and go as agents are created and deleted.
  document.addEventListener('click', function (e) {
    var btn = e.target.closest && e.target.closest('.agent-row-actions button');
    if (!btn) return;
    e.preventDefault();
    var box = btn.parentNode;
    var key = box.getAttribute('data-agent-key');
    var action = btn.getAttribute('data-agent-action');
    if (action === 'edit') withAgent(key, openAgentForm);
    else if (action === 'run') runAgentRow(btn, key);
    else if (action === 'clear') clearAgentLog(key);
    else if (action === 'delete') deleteAgentRow(box, key);
  });

  function runAgentRow(btn, key) {
    if (btn.disabled) return;
    btn.disabled = true;
    btn.title = ai18n.running;
    fetch(customAgentsUrl + '/' + key + '/run', { method: 'POST', headers: jsonHeaders() })
      .then(function (res) { return res.json(); })
      .then(function (data) {
        if (!data || !data.run_id) throw new Error('run not started');
        pollRun(key, data.run_id, 0, function () {
          // Only the open agent's page shows what the run wrote.
          if (key === currentAgentKey) { window.location.reload(); return; }
          btn.disabled = false;
          btn.title = ai18n.runNow;
        });
      })
      .catch(function () {
        btn.disabled = false;
        btn.title = ai18n.runNow;
      });
  }

  function clearAgentLog(key) {
    if (!window.confirm(i18n.clearConfirm)) return;
    fetch(clearUrl.split('?')[0] + '?agent_key=' + encodeURIComponent(key),
          { method: 'DELETE', headers: jsonHeaders(), body: JSON.stringify({ all: '1' }) })
      .then(function (res) { return res.json(); })
      .then(function () {
        if (key !== currentAgentKey) return;
        clearChat();
        currentChatId = newChatId();
        setHasMessages(false);
      });
  }

  function deleteAgentRow(box, key) {
    if (!window.confirm(ai18n.deleteAgentConfirm)) return;
    fetch(customAgentsUrl + '/' + key, { method: 'DELETE', headers: jsonHeaders() })
      .then(function (res) { return res.json(); })
      .then(function () {
        // This page goes with the agent; the bare URL is the Query Agent's.
        if (key === currentAgentKey) { window.location.href = window.location.pathname; return; }
        var li = box.parentNode;
        if (li && li.parentNode) li.parentNode.removeChild(li);
      });
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

  function parseCronForForm(cron) {
    if (!cron) {
      return { frequency: 'none', time: '09:00', weekday: '0', day: '1',
               every: '4', minute: '0', timezone: defaultTimezone };
    }
    var parts = cron.trim().split(/\s+/);
    var min = parts[0], hour = parts[1], dom = parts[2], dow = parts[4], tz = parts[5] || defaultTimezone;
    var time = (hour.length < 2 ? '0' + hour : hour) + ':' + (min.length < 2 ? '0' + min : min);
    var frequency = 'daily', weekday = '0', day = '1', every = '4', minute = '0';
    // An hour step ("*/4") or a bare "*" is an interval, not a time of day.
    var step = /^\*\/(\d+)$/.exec(hour);
    if (step || hour === '*') {
      frequency = 'hourly';
      every = step ? step[1] : '1';
      minute = String(parseInt(min, 10) || 0);
    }
    else if (dow === '1-5') { frequency = 'weekdays'; }
    else if (dow !== '*') { frequency = 'weekly'; weekday = dow; }
    else if (dom !== '*') { frequency = 'monthly'; day = dom; }
    return { frequency: frequency, time: time, weekday: weekday, day: day,
             every: every, minute: minute, timezone: tz };
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
    if (!modal) return;
    modal.hidden = true;
    // Core's warnLeavingUnsaved scans every textarea in the document and only
    // clears the flag on a real form submit — this form saves over fetch, so a
    // left-behind task field would warn on every later navigation. The form is
    // rebuilt on each open anyway.
    modal.innerHTML = '';
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

    // Blank unless MCP servers are configured — those are the notify channels.
    if (ai18n.notifyChannels) {
      var notifyHint = document.createElement('p');
      notifyHint.className = 'agent-form-hint';
      notifyHint.textContent = ai18n.notifyChannels;
      form.appendChild(notifyHint);
    }

    var schedLabel = document.createElement('div');
    schedLabel.className = 'agent-form-section-label';
    schedLabel.textContent = ai18n.agentSchedule;
    form.appendChild(schedLabel);

    var schedFields = document.createElement('div');
    schedFields.className = 'agent-sched-fields';

    // 'none' replaces the old on/off checkbox — it is how an agent is left unscheduled.
    var freqSelect = document.createElement('select');
    freqSelect.className = 'multi-row';
    [['none', ai18n.freqNone], ['hourly', ai18n.freqHourly], ['daily', ai18n.freqDaily], ['weekdays', ai18n.freqWeekdays], ['weekly', ai18n.freqWeekly], ['monthly', ai18n.freqMonthly]]
      .forEach(function (pair) {
        var opt = document.createElement('option');
        opt.value = pair[0];
        opt.textContent = pair[1];
        if (sched.frequency === pair[0]) opt.selected = true;
        freqSelect.appendChild(opt);
      });
    schedFields.appendChild(labeled(textLabel(ai18n.freqLabel), freqSelect));

    // "Every N hours at minute M". Only 24's divisors are offered: a step like
    // */5 would leave a short gap at midnight instead of an even interval.
    var everySelect = document.createElement('select');
    everySelect.className = 'multi-row';
    [1, 2, 3, 4, 6, 8, 12].forEach(function (n) {
      var opt = document.createElement('option');
      opt.value = String(n);
      opt.textContent = String(n);
      if (String(sched.every) === String(n)) opt.selected = true;
      everySelect.appendChild(opt);
    });

    var minuteSelect = document.createElement('select');
    minuteSelect.className = 'multi-row';
    for (var m = 0; m < 60; m += 5) {
      var mOpt = document.createElement('option');
      mOpt.value = String(m);
      mOpt.textContent = (m < 10 ? '0' : '') + m;
      if (String(sched.minute) === String(m)) mOpt.selected = true;
      minuteSelect.appendChild(mOpt);
    }

    var intervalFields = document.createElement('div');
    intervalFields.className = 'agent-interval-fields';
    var hoursText = document.createElement('span');
    hoursText.textContent = ai18n.hoursLabel;
    intervalFields.appendChild(everySelect);
    intervalFields.appendChild(hoursText);
    intervalFields.appendChild(minuteSelect);
    var intervalRow = labeled(textLabel(ai18n.everyLabel), intervalFields);
    schedFields.appendChild(intervalRow);

    var timeInput = document.createElement('input');
    timeInput.type = 'time';
    timeInput.value = sched.time;
    var timeRow = labeled(textLabel(ai18n.timeLabel), timeInput);
    // The zone is never asked for, so say which one the time is read in.
    if (sched.timezone) {
      var tzHint = document.createElement('p');
      tzHint.className = 'agent-form-hint';
      tzHint.textContent = ai18n.timezone + ': ' + sched.timezone;
      timeRow.appendChild(tzHint);
    }
    schedFields.appendChild(timeRow);

    var weekdaySelect = document.createElement('select');
    weekdaySelect.className = 'multi-row';
    // date.day_names is 0-indexed from Sunday, same as cron's day-of-week.
    ai18n.dayNames.forEach(function (d, i) {
      var opt = document.createElement('option');
      opt.value = i;
      opt.textContent = d;
      if (String(sched.weekday) === String(i)) opt.selected = true;
      weekdaySelect.appendChild(opt);
    });
    var weekdayRow = labeled(textLabel(ai18n.weekdayLabel), weekdaySelect);
    schedFields.appendChild(weekdayRow);

    // 1-28 plus "L" (fugit's last-day-of-month), so a day that some months
    // don't have can't be picked at all.
    var daySelect = document.createElement('select');
    daySelect.className = 'multi-row';
    var dayOptions = [];
    for (var dnum = 1; dnum <= 28; dnum++) dayOptions.push([String(dnum), String(dnum)]);
    // An agent saved on 29-31 predates this list; keep its value as an option so
    // opening the form doesn't silently move its schedule to the 1st.
    if (/^(29|30|31)$/.test(String(sched.day))) dayOptions.push([String(sched.day), String(sched.day)]);
    dayOptions.push(['L', ai18n.lastDay]);

    dayOptions.forEach(function (pair) {
      var opt = document.createElement('option');
      opt.value = pair[0];
      opt.textContent = pair[1];
      if (String(sched.day) === pair[0]) opt.selected = true;
      daySelect.appendChild(opt);
    });
    var dayRow = labeled(textLabel(ai18n.dayLabel), daySelect);

    var dayHint = document.createElement('p');
    dayHint.className = 'agent-form-hint';
    dayHint.textContent = ai18n.dayWarning;
    dayRow.appendChild(dayHint);

    function syncDayHint() {
      dayHint.hidden = !/^(29|30|31)$/.test(daySelect.value);
    }
    daySelect.addEventListener('change', syncDayHint);
    syncDayHint();

    schedFields.appendChild(dayRow);

    form.appendChild(schedFields);

    function syncSchedVisibility() {
      // Hourly sets its own minute, and its hour is the interval — no time of day.
      intervalRow.hidden = freqSelect.value !== 'hourly';
      timeRow.hidden = freqSelect.value === 'none' || freqSelect.value === 'hourly';
      weekdayRow.hidden = freqSelect.value !== 'weekly';
      dayRow.hidden = freqSelect.value !== 'monthly';
    }
    freqSelect.addEventListener('change', syncSchedVisibility);
    syncSchedVisibility();

    // No delivery channels here any more: whatever the agent should send goes
    // out as an MCP tool call its task asks for.
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
      if (!name) { errorMsg.textContent = ai18n.errNameBlank; return; }
      if (!task) { errorMsg.textContent = ai18n.errTaskBlank; return; }
      var needsTime = freqSelect.value !== 'none' && freqSelect.value !== 'hourly';
      if (needsTime && !timeInput.value) { errorMsg.textContent = ai18n.errSchedule; return; }

      var payload = {
        name: name,
        task: task
      };
      payload.frequency = freqSelect.value;
      if (freqSelect.value === 'hourly') {
        payload.every = everySelect.value;
        payload.minute = minuteSelect.value;
      } else if (freqSelect.value !== 'none') {
        payload.time = timeInput.value;
        payload.weekday = weekdaySelect.value;
        payload.day = daySelect.value;
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
          // The header carries the agent's name on its own page.
          var heading = document.querySelector('#agent-chat-header h2');
          if (heading && res.data.agent && res.data.agent.key === currentAgentKey) {
            heading.textContent = res.data.agent.name;
          }
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

  if (addAgentBtn) addAgentBtn.addEventListener('click', function () { openAgentForm(null); });

  decorateAgentMenuRows();
});
