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
});
