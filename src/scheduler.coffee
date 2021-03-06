promise = require 'promise'
semver  = require 'semver'

DEFAULT_KEY                       = '__default'
BLACK_SCREEN                      = '__bs'
# Health checks are disabled right after the scheduler starts for
# HC_WARMUP_DURATION msecs.
HC_WARMUP_DURATION                = 60 * 1000
# Time between two run() calls. Scheduler will fail the health checks
# when this threshold is exceeded.
HC_RUN_CALL_THRESHOLD             = 3 * 60 * 1000
# Time between two successful renders. Scheduler will fail the health
# checks when this threshold is exceeded.
HC_SUCCESSFUL_RUN_CALL_THRESHOLD  = 3 * 60 * 1000
# Time to wait for the app to reply back to the prepare() call. Timeout
# value should be high enough to compensate slow connections.
PREPARE_TIMEOUT                   = 5 * 60 * 1000
# The scheduler will allow rendering only a number of immediate views
# per app.
MAX_IMMEDIATE_VIEWS_PER_APP       = 3

# A basic Cortex scheduler.
#
# This scheduler accepts a strategy and runs one app at a time fullscreen.
# A strategy is a list of priority levels. Lower indexes have higher
# importance. Each priority level consists of a list of applications.
# Priority levels can have multiple instances of the same app. Here is a sample
# strategy:
#
# [
#   ['ads', 'ads', 'editorial']
#   ['editorial', 'static-images']
#   ['static-images']
# ]
#
# The scheduler creates a view queue for each application (@_queues). For the
# above strategy, the scheduler would create 3 view queues. Applications may
# pass a content id with each prepare() call. In this case, the scheduler will
# create additional queues per unique content id.
#
# Priority Behavior:
#
#  - The very first step starts at P0-A0.
#  - During a step, we try a single priority level.
#  - During a step, we try the remaining apps of a priority level.
#  - When a step succeeds, we advance the app index, so next time we try the
#    same priority level, we'll try the next app in that level.
#  - When a step succeeds, if we are not at the top priority level, we reset
#    app indexes of all top level priority levels and start at P0-A0.
#  - When a step fails (no render), we move to the next priority level.
#  - When a step fails and we tried all apps, the scheduler will sleep for
#    some time and report a black screen.
#
# Sample run:
#   P0: ['a', 'b', 'c']
#   P1: ['d', 'e', 'f']
#   P2: ['g', 'h', 'i']
#
# Step 1: Try 'a'. (Assume rendering status to be: Success)
# Step 2: Try 'b'. (Success)
# Step 3: Try 'c'. (Success)
# Step 4: Try 'a'. (Success)
# Step 5: Try 'b'. (Fail)
# Step 6: Try 'c'. (Fail)
# Step 7: Try 'a'. (Fail)
# Step 8: Try 'd'. (Fail)
# Step 9: Try 'e'. (Success)
# Step 10: Try 'a'. (Fail)
# Step 11: Try 'b'. (Fail)
# Step 12: Try 'c'. (Fail)
# Step 13: Try 'f'. (Fail)
# Step 14: Try 'a'. (Fail)
# Step 15: Try 'b'. (Fail)
# Step 16: Try 'c'. (Fail)
# Step 17: Try 'd'. (Fail)
# Step 18: Try 'e'. (Fail)
# Step 19: Try 'f'. (Fail)
# Step 20: Try 'g'. (Success)
# Step 21: Try 'a'...
#
# Unique Content:
# The scheduler guarantees it will show unique content if an app provides
# content ids. The scheduler will skip (not discard) a view, if the currently
# tested app is the same as the currently rendered one and the tested view has
# the same id as the currently rendered view.
#
# Immediate Views:
# The scheduler accepts immediate views from apps with requestFocus() calls.
# Immediate views are kept in separate queues and at the beginning of a step
# the scheduler will try to render an immediate view first. To give regular
# views a chance, the scheduler limits consecutive immediate views to
# MAX_IMMEDIATE_VIEWS_PER_APP. A black screen or a regular view will reset
# the counters.
#
# Immediate views are also subject to duplicate content prevention.
#
class DefaultScheduler
  constructor: (@_bufferedViewsPerApp, @_playerVersion) ->
    # Cortex player has a breaking API change as of 2.4.0. The scheduler should
    # rely on node style callbacks when using Cortex.scheduler.hideRenderShow()
    # for performance reasons. On older players, the scheduler should use the
    # returned promise.
    #
    # TODO(hkaya): Remove this logic when all players are upgraded to 2.4.0.
    @_shouldUsePromises = semver.lt(@_playerVersion, '2.4.0')
    console.warn "Cortex.scheduler.hideRenderShow will use promise: " +
      "#{@_shouldUsePromises}"

    # The last successfully rendered app.
    @_currentApp          = undefined
    # The last successfully rendered view.
    @_currentView         = undefined
    # Keeps track of the priority index to be tried during the next step.
    @_priorityIndex       = 0
    # View queues for each app. Each app will start with a default queue, but
    # they can create additional queues by passing a content id with prepare()
    # calls. e.g.
    # @_queues = {
    #   'app1': {
    #     '__default': [{viewId: 'v1'}, {viewId: 'v2'}],
    #     'content-id-1': [{viewId: 'v3', contentLabel: 'c3'}]
    #   'app2': {
    #     '__default': [...]
    @_queues              = {}
    # Views submitted using requestFocus(). Scheduler will prioritize these
    # views over any view in @_queues.
    # @_immediateViewQueues = {
    #   'app1': [{viewId: 'v1'}, {viewId: 'v2', contentId: 'v2'}],
    #   'app2': [...]
    @_immediateViewQueues = {}
    # Keeps track of consecutive immediate views. An application can take
    # control of the screen by constantly submitting views using
    # requestFocus(). To prevent this, the scheduler will render only a
    # number of views from an app consecutively. After an app hits the
    # threshold the scheduler will try to render a view from reqular
    # queues.
    @_consecutiveImmediateRenders = {}
    # Keeps track of prepare() calls made to the apps in order not to flood
    # apps.
    @_activePrepareCalls  = {}
    # Keeps track of last tried view queue index for each app. For instance,
    # if @_appViewIndex['app1'] is 2, this means we tried the third queue of
    # app1. During the next run, we should try the fourth queue (or first, if
    # it doesn't have four queues) of app1.
    @_appViewIndex        = {}
    # Similar to appViewIndex, this keeps track of tried apps within a priority
    # level.
    @_priorityAppIndex    = []

    # Number of unique apps in a strategy.
    @_totalAppSlots       = 0
    # Failed unique app count so far. When an app renders, this counter will
    # get reset.
    @_failedAppSlots      = 0
    # Keep track of step start time for measurements.
    @_stepStartTime       = 0
    # Keep track of render start time for measurements.
    @_renderStartTime     = 0

    @_stats =
      steps: 0
      successfulRuns: 0
      failedRuns: 0
      blackScreens: 0
      priorities: {}
      immidiateViews: {}
      apiCalls:
        prepare: {}
        discardView: {}
        requestFocus: {}
        hideRenderShow: {}
      appViews: {}

    printStats = =>
      regular = {}
      for app, queue of @_queues
        total = 0
        for qname, views of queue
          total += views.length
        regular[app] = total

      immediate = {}
      for app, queue of @_immediateViewQueues
        immediate[app] = queue.length

      stats =
        regularViews: regular
        immediateViews: immediate
        stats: @_stats
      console.log JSON.stringify(stats)

    setInterval printStats, 60000

  start: (@_api, @_strategy) ->
    @_startTime             = new Date().getTime()
    @_lastRunTime           = new Date().getTime()
    @_lastSuccessfulRunTime = new Date().getTime()

    @_apps = @_extractAppList @_strategy
    @_initPriorityQueues()

    @_api.scheduler.onAppCrash @_onAppCrash
    @_api.scheduler.onRequestFocus @_onRequestFocus

    @_run()

    @_api.app.registerHealthCheck @_onHealthCheck

  _onAppCrash: (appId) =>
    console.log "Received an app crash: #{appId}"
    @_queues[appId] = "#{DEFAULT_KEY}": []
    @_immediateViewQueues[appId] = []
    @_activePrepareCalls[appId] = 0

  _onRequestFocus: (app, view) =>
    if not (app of @_apps) or not view?.viewId
      @_stats.apiCalls?.requestFocus?[app]?.failure += 1
      return

    @_immediateViewQueues[app].push
      viewId:       view?.viewId
      contentId:    view?.contentId
      contentLabel: view?.contentLabel
      expiration:   @_expirationTime(view?.ttl)

    @_stats.apiCalls?.requestFocus?[app]?.success += 1

  _onHealthCheck: (report) =>
    now = new Date().getTime()
    if now < @_startTime + HC_WARMUP_DURATION
      # Ignore health checks during the warm up period.
      report status: true
      return

    if now > @_lastRunTime + HC_RUN_CALL_THRESHOLD
      # No run() calls.
      report status: false, reason: 'Scheduler has stopped working.'
      return

    if now > @_lastSuccessfulRunTime + HC_SUCCESSFUL_RUN_CALL_THRESHOLD
      # No successfull render() calls.
      report
        status: false
        reason: "Scheduler hasn't rendered any content for too long."
      return

    report status: true

  _run: =>
    if not @_strategy? or @_strategy.length == 0
      throw new Error 'Scheduler cannot run without a strategy'

    @_lastRunTime = new Date().getTime()
    @_prepareApps()
    @_expireViews()
    @_runStep()

  _runStep: ->
    startTime = new Date().getTime()
    console.log "Last step took #{startTime - @_stepStartTime}msecs."
    @_stepStartTime = startTime
    @_stats.steps += 1

    new promise (resolve, reject) =>
      @_tryImmediateView()
        .then =>
          @_stats.successfulRuns += 1
          process.nextTick @_run
          resolve()
        .catch =>
          if @_priorityIndex >= @_strategy.length
            # During the previous step we tried all available priority levels
            # and still failed. We need to start from the top.
            @_priorityIndex = 0

          if @_priorityAppIndex[@_priorityIndex] >= \
              @_strategy[@_priorityIndex].length
            @_priorityAppIndex[@_priorityIndex] = 0

          @_tryPriority @_priorityIndex, @_priorityAppIndex[@_priorityIndex]
            .then =>
              @_stepSucceeded()
              resolve()
            .catch (e) =>
              @_stepFailed()
              reject e

  _stepSucceeded: ->
    @_stats.successfulRuns += 1
    @_stats.priorities?[@_priorityIndex]?.success += 1
    @_failedAppSlots = 0
    @_lastSuccessfulRunTime = new Date().getTime()

    # Move to the next app in the same priority level.
    @_priorityAppIndex[@_priorityIndex] += 1

    # Next step will start from the top. We need to reset app indexes in
    # all higher priority levels.
    if @_priorityIndex != 0
      for pi in [0..@_priorityIndex - 1]
        @_priorityAppIndex[pi] = 0
    @_priorityIndex = 0

    @_resetImmediateViewCounters()
    process.nextTick @_run

  _stepFailed: ->
    @_stats.priorities?[@_priorityIndex]?.failure += 1
    @_priorityAppIndex[@_priorityIndex] = 0
    # All apps in this priority level has failed. Move to the next level.
    @_priorityIndex += 1
    @_failedAppSlots += 1
    @_stats.failedRuns += 1

    if @_failedAppSlots >= @_totalAppSlots
      @_failedAppSlots = 0
      @_stats.blackScreens += 1
      # All priority levels tested. Slow down and notify user.
      @_api.scheduler.trackView BLACK_SCREEN
      # Reset the current app & view to allow duplicate content to be
      # displayed after a black screen. Not resetting these values
      # will cause a scheduler fail under the following conditions:
      #   - There's only one app
      #   - The app offers unique views
      #   - Currently the app queue has max. number of views for that app
      #   - All views has the same id
      @_currentApp = undefined
      @_currentView = undefined
      @_resetImmediateViewCounters()
      global.setTimeout @_run, 1000
    else
      process.nextTick @_run

  _resetImmediateViewCounters: ->
    for app, s of @_apps
      @_consecutiveImmediateRenders[app] = 0

  _tryImmediateView: ->
    new promise (resolve, reject) =>
      for app, views of @_immediateViewQueues
        if @_consecutiveImmediateRenders[app] >= MAX_IMMEDIATE_VIEWS_PER_APP
          continue

        if views.length == 0
          continue

        for view, idx in views
          if (@_currentApp == app) and \
              (not not @_currentView?.contentId) and \
              (view?.contentId == @_currentView?.contentId)
            @_stats?.immidiateViews?[app]?.preventDuplicates += 1
            continue

          deleted = views.splice(idx, 1)
          @_render app, deleted[0]
            .then =>
              @_stats?.immidiateViews?[app]?.success += 1
              @_consecutiveImmediateRenders[app] += 1
              resolve()
            .catch (e) =>
              @_stats?.immidiateViews?[app]?.failure += 1
              reject e
          return

      reject()

  _tryPriority: (priorityIndex, appIndex) ->
    new promise (resolve, reject) =>
      if (not @_strategy or priorityIndex >= @_strategy.length \
          or priorityIndex < 0)
        return reject()

      priority = @_strategy[priorityIndex]
      if appIndex < 0 or appIndex >= priority.length
        return reject()

      @_tryPriorityApp priority, appIndex
        .then resolve
        .catch =>
          process.nextTick =>
            @_tryPriority priorityIndex, appIndex + 1
              .then resolve
              .catch reject

  _tryPriorityApp: (priority, appIndex) ->
    new promise (resolve, reject) =>
      if not priority? or appIndex >= priority.length or appIndex < 0
        return reject()

      @_tryApp priority[appIndex]
        .then resolve
        .catch reject

  _tryApp: (app) ->
    new promise (resolve, reject) =>
      if not @_queues or not (app of @_queues)
        return reject()

      queue = @_queues[app]

      contentIds = Object.keys(queue)
      if contentIds.length == 0
        return reject()

      if app not in @_appViewIndex
        @_appViewIndex[app] = 0

      view = @_findView(app, queue, contentIds, @_appViewIndex[app] + 1)
      if view?
        @_stats.appViews?[app]?.success += 1
        return @_render app, view
          .then resolve
          .catch reject
      else
        @_stats.appViews?[app]?.failure += 1
        bucketsWithViews = 0
        for contentId, views of queue
          if views?.length > 0
            bucketsWithViews += 1

        if bucketsWithViews > 0
          @_stats.appViews?[app]?.preventDuplicates += 1
        if bucketsWithViews > 1
          # This shouldn't happen.
          @_stats.appViews?[app]?.duplicateLogicFailures += 1

      reject()

  _findView: (app, queue, contentIds, index) ->
    if index >= contentIds.length
      index = 0

    contentId = contentIds[index]
    views = queue[contentId]
    if views.length > 0
      if contentIds.length == 1 or @_currentApp != app
        # Either the candidate app is different than the last rendered one or
        # the candidate app doesn't provide content ids. In either case we
        # shouldn't check for uniqueness.
        @_appViewIndex[app] = index
        return views.shift()
      else
        for view, idx in views
          if view?.contentId != @_currentView?.contentId
            @_appViewIndex[app] = index
            deleted = views.splice(idx, 1)
            return deleted[0]

    if @_appViewIndex[app] == index
      return

    return @_findView(app, queue, contentIds, index + 1)

  _render: (app, view) ->
    startTime = new Date().getTime()
    console.log "Last render took #{startTime - @_renderStartTime}msecs."
    @_renderStartTime = startTime

    console.log "Rendering #{app}/#{view.contentId}/#{view.viewId}."
    st = new Date().getTime()
    @_stats.apiCalls?.hideRenderShow?[app]?.active += 1

    @_inProgressView =
      appId:  app
      viewId: view.viewId

    new promise (resolve, reject) =>
      fail = (err) =>
        @_stats.apiCalls?.hideRenderShow?[app]?.active -= 1
        @_stats.apiCalls?.hideRenderShow?[app]?.failure += 1
        reject err

      success = =>
        @_stats.apiCalls?.hideRenderShow?[app]?.active -= 1
        @_stats.apiCalls?.hideRenderShow?[app]?.success += 1
        et = new Date().getTime()
        console.log """#{app}/#{view.contentId}/#{view.viewId} rendered in \
          #{et - st} msecs."""
        @_currentApp = app
        @_currentView = view
        @_api.scheduler.trackView app, view.contentLabel
        resolve()

      if @_shouldUsePromises
        # use promises
        @_api.scheduler.hideRenderShow @_currentApp, view.viewId, app
          .then success
          .catch fail

      else
        # use callback
        @_api.scheduler.hideRenderShow @_currentApp, view.viewId, app, (err) =>
          if err?
            return fail(err)

          success()

  _expireViews: ->
    now = new Date().getTime()
    for appId, appQ of @_queues
      if not appQ?
        continue
      @_queues[appId] = {}
      for contentId, views of appQ
        @_queues[appId][contentId] = []
        for view in views
          if @_isExpired(appId, view.viewId, view.expiration, now)
            @_expire(appId, view.viewId)
            continue

          @_queues[appId][contentId].push view

    for appId, appQ of @_immediateViewQueues
      @_immediateViewQueues[appId] = []
      for view in appQ
        if @_isExpired(appId, view.viewId, view.expiration, now)
          @_expire(appId, view.viewId)
          continue

        @_immediateViewQueues[appId].push view

  _isExpired: (appId, viewId, expiration, now) ->
    inProgress = appId == @_inProgressView?.appId and \
      viewId == @_inProgressView?.viewId

    expired = expiration? and expiration <= now and expiration > 0

    expired and not inProgress

  _expire: (appId, viewId) ->
    @_stats.apiCalls.discardView[appId].active += 1
    Cortex.scheduler.discardView appId, viewId
      .then =>
        @_stats.apiCalls.discardView[appId].active -= 1
        @_stats.apiCalls.discardView[appId].success += 1
      .catch (e) =>
        @_stats.apiCalls.discardView[appId].active -= 1
        @_stats.apiCalls.discardView[appId].failure += 1
        console.warn "Scheduler failed to discard view. appId: #{appId}, " +
          "viewId: #{viewId}", e

  _prepareApps: ->
    for app, s of @_apps
      appQ = @_queues?[app]
      reqCnt = 0
      if appQ?
        viewCnt = 0
        for v, q of appQ
          viewCnt += q?.length || 0
        reqCnt = @_bufferedViewsPerApp - viewCnt
      else
        reqCnt = @_bufferedViewsPerApp

      reqCnt = reqCnt - @_activePrepareCalls[app]
      if reqCnt > 0
        for i in [1..reqCnt]
          @_prepare app

  _prepare: (app) ->
    new promise (resolve, reject) =>
      @_activePrepareCalls[app] = @_activePrepareCalls[app] + 1
      @_stats.apiCalls?.prepare?[app]?.active += 1

      expire = =>
        @_stats.apiCalls?.prepare?[app]?.failure += 1
        @_stats.apiCalls?.prepare?[app]?.timeout += 1
        @_stats.apiCalls?.prepare?[app]?.active -= 1
        @_activePrepareCalls[app] = @_activePrepareCalls[app] - 1
        console.error "prepare() call timed out for app #{app}."
        reject new Error("prepare() call timed out.")
      timer = setTimeout expire, PREPARE_TIMEOUT

      @_api.scheduler.prepare app
        .then (resp) =>
          clearTimeout timer
          @_stats.apiCalls?.prepare?[app]?.success += 1
          @_activePrepareCalls[app] = @_activePrepareCalls[app] - 1
          @_stats.apiCalls?.prepare?[app]?.active -= 1
          if not not resp?.viewId
            viewId = resp.viewId
            contentId = resp?.contentId || DEFAULT_KEY
            contentLabel = resp?.contentLabel
            if not (contentId of @_queues[app])
              @_queues[app][contentId] = []
            @_queues[app][contentId].push
              viewId:       viewId
              contentId:    contentId
              contentLabel: contentLabel
              expiration:   @_expirationTime(resp?.ttl)
          resolve()
        .catch (e) =>
          clearTimeout timer
          @_stats.apiCalls?.prepare?[app]?.failure += 1
          @_stats.apiCalls?.prepare?[app]?.active -= 1
          @_activePrepareCalls[app] = @_activePrepareCalls[app] - 1
          console.error "prepare() call failed for app #{app}.", e
          reject e

  _initPriorityQueues: ->
    @_queues = {}
    @_activePrepareCalls = {}
    for app, s of @_apps
      @_stats.apiCalls.prepare[app] =
        success: 0
        failure: 0
        timeout: 0
        active:  0
      @_stats.apiCalls.discardView[app] =
        success: 0
        failure: 0
        active:  0
      @_stats.apiCalls.requestFocus[app] =
        success: 0
        failure: 0
      @_stats.apiCalls.hideRenderShow[app] =
        success: 0
        failure: 0
        active:  0
      @_stats.appViews[app] =
        success: 0
        failure: 0
        preventDuplicates: 0
        duplicateLogicFailures: 0
      @_stats.immidiateViews[app] =
        success: 0
        failure: 0
        preventDuplicates: 0
      @_queues[app] = "#{DEFAULT_KEY}": []
      @_immediateViewQueues[app] = []
      @_consecutiveImmediateRenders[app] = 0
      @_activePrepareCalls[app] = 0
      @_appViewIndex[app] = 0

  _extractAppList: (strategy) ->
    apps = {}
    for priority, idx in strategy
      @_stats.priorities[idx] =
        success: 0
        failure: 0
      @_priorityAppIndex.push 0
      for app in priority
        @_totalAppSlots += 1
        apps[app] = true

    apps

  _expirationTime: (ttl) ->
    if not ttl?
      return 0

    ttl = parseInt(ttl)
    if isNaN(ttl) || ttl <= 0
      return 0

    return new Date().getTime() + ttl

module.exports = {
  DefaultScheduler,
  DEFAULT_KEY,
  BLACK_SCREEN,
  HC_WARMUP_DURATION,
  HC_RUN_CALL_THRESHOLD,
  HC_SUCCESSFUL_RUN_CALL_THRESHOLD,
  PREPARE_TIMEOUT,
  MAX_IMMEDIATE_VIEWS_PER_APP
}
