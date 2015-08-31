promise = require 'promise'

DEFAULT_KEY             = '__default'
BUFFERED_VIEWS_PER_APP  = 5

class DefaultScheduler
  start: (@_api, @_strategy) ->
    @_currentApp    = undefined
    @_priorityIndex = 0
    @_appIndex      = 0
    @_queues        = {}
    @_beginTime     = 0
    @_endTime       = 0

    @_apps = @_extractAppList @_strategy
    @_initPriorityQueues()

    @_prepareApps()
    @_run()

  _run: ->
    @_runStep()

  _runStep: ->
    if not @_strategy? or @_strategy.length == 0
      throw new Error 'Scheduler cannot run without a strategy'

    if @_priorityIndex >= @_strategy.length
      @_priorityIndex = 0
      @_appIndex = 0

    new promise (resolve, reject) =>
      @_tryPriority @_priorityIndex, @_appIndex
        .then =>
          if @_priorityIndex == 0
            # We are at the top level. Try the next app in this priority level.
            @_appIndex = @_appIndex + 1
            if @_appIndex >= @_strategy[@_priorityIndex].length
              @_appIndex = 0
          else
            # An app in a lower level priority got rendered. Start from the top
            # level in the next cycle.
            @_priorityIndex = 0
            @_appIndex = 0
          process.nextTick => @_run()
          resolve()
        .catch (e) =>
          # All apps in this priority level has failed. Move to the next level.
          @_priorityIndex += 1
          @_appIndex = 0
          process.nextTick => @_run()
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
      for contentId, views of queue
        if views.length == 0
          continue

        view = views[0]
        @_render app, view
          .then =>
            @_discardView app, view
            resolve()
          .catch reject
        return

      reject()

  _render: (app, view) ->
    console.log "Rendering #{app}/#{view.contentId}/#{view.viewId}."
    st = new Date().getTime()
    new promise (resolve, reject) =>
      # We can't use promise.all() to combine the showHide() and render()
      # promises since we need to set _currentApp when showHide() succeeds
      # regardless of the overall success of the _render.
      rejected = false
      resolveCnt = 0

      # Reject only once.
      onError = (e) ->
        if not rejected
          rejected = true
          reject e

      # Resolve only when both promises resolve.
      onSuccess = ->
        resolveCnt = resolveCnt + 1
        if resolveCnt == 2
          et = new Date().getTime()
          console.log """#{app}/#{view.contentId}/#{view.viewId} rendered \
            in #{et - st} msecs."""
          resolve()

      @_api.scheduler.showHide app, @_currentApp
        .then =>
          @_currentApp = app
          onSuccess()
        .catch onError

      @_api.scheduler.render app, view.viewId
        .then onSuccess
        .catch =>
          @_discardView app, view
          onError()

  _prepareApps: ->
    for app, s of @_apps
      for i in [1..BUFFERED_VIEWS_PER_APP]
        @_prepare app

  _prepare: (app) ->
    new promise (resolve, reject) =>
      @_api.scheduler.prepare app
        .then (resp) =>
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
          resolve()
        .catch (e) ->
          console.log "prepare() call failed for app #{app}. e=#{e?.message}"
          reject()

  _discardView: (app, view) ->
    appQ = @_queues?[app]
    viewQ = appQ?[view?.contentId]
    if viewQ?.length > 0
      viewQ.shift()
      @_prepare app

  _initPriorityQueues: ->
    @_queues = {}
    for app, s of @_apps
      @_queues[app] = "#{DEFAULT_KEY}": []

  _extractAppList: (strategy) ->
    apps = {}
    for priority in strategy
      for app in priority
        apps[app] = true

    apps

module.exports = DefaultScheduler
