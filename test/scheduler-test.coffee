require './test-case'
expect    = require('chai').expect
sinon     = require 'sinon'
promise   = require 'promise'

DefaultScheduler = require '../src/scheduler'

describe 'Scheduler', ->
  beforeEach ->
    @hideRenderShow = sinon.stub()
    @prepare = sinon.stub()
    @trackView = sinon.stub()
    @api =
      scheduler:
        prepare: @prepare
        hideRenderShow: @hideRenderShow
        trackView: @trackView
    @clock = sinon.useFakeTimers()
    @scheduler = new DefaultScheduler()
    @scheduler._api = @api

  afterEach ->
    @clock.restore()

  describe '#_onHealthCheck', ->
    it 'should succeed during the warmup period', ->
      report = sinon.stub()
      @scheduler._onHealthCheck report
      expect(report).to.have.been.calledOnce
      expect(report).to.have.been.calledWith status: true
      report.reset()

      @clock.tick 5000
      @scheduler._onHealthCheck report
      expect(report).to.have.been.calledOnce
      expect(report).to.have.been.calledWith status: true

    it 'should fail when there have been no run calls', ->
      rs = sinon.stub @scheduler, '_runStep', ->
      # warm up
      @clock.tick 60000
      @scheduler._strategy = [['a']]
      @scheduler._run()
      @clock.tick 200000

      report = sinon.stub()
      @scheduler._onHealthCheck report
      expect(report).to.have.been.calledOnce
      expect(report).to.have.been.calledWith
        status: false
        reason: 'Scheduler has stopped working.'

    it 'should fail when there have been no successful renders', ->
      # warm up
      @clock.tick 500000
      now = new Date().getTime()
      @scheduler._lastRunTime = now
      @scheduler._lastSuccessfulRunTime = now - 300000

      report = sinon.stub()
      @scheduler._onHealthCheck report
      expect(report).to.have.been.calledOnce
      expect(report).to.have.been.calledWith
        status: false
        reason: "Scheduler hasn't rendered any content for too long."

    it 'should succeed when everything is alright', ->
      @clock.tick = 500000
      now = new Date().getTime()
      @scheduler._lastRunTime = now
      @scheduler._lastSuccessfulRunTime = now

      report = sinon.stub()
      @scheduler._onHealthCheck report
      expect(report).to.have.been.calledOnce
      expect(report).to.have.been.calledWith status: true

  describe '#_run', ->
    it 'should throw when strategy is invalid', ->
      expect(@scheduler._strategy).to.not.be.ok
      expect(=> @scheduler._run()).to.throw
      @scheduler._strategy = []
      expect(=> @scheduler._run()).to.throw

  describe '#_runStep', ->
    it 'should try an app of a priority', ->
      @scheduler._priorityIndex = 1
      @scheduler._appIndex = 0
      tp = sinon.stub @scheduler, '_tryPriority', ->
        then: ->
          catch: ->
      @scheduler._strategy = [
        ['a', 'b'],
        ['c', 'd'],
        ['e']
      ]
      @scheduler._runStep()
      expect(tp).to.have.been.calledOnce
      expect(tp).to.have.been.calledWith 1, 0

    it 'should reset the indexes when priority index is out of bounds', ->
      @scheduler._priorityIndex = 6
      @scheduler._appIndex = 1
      tp = sinon.stub @scheduler, '_tryPriority', ->
        then: ->
          catch: ->
      @scheduler._strategy = [
        ['a', 'b'],
        ['c', 'd'],
        ['e']
      ]
      @scheduler._runStep()
      expect(tp).to.have.been.calledOnce
      expect(tp).to.have.been.calledWith 0, 0

    it 'should move to the next app when current app renders and priority is \
        top level', (done) ->
      @scheduler._priorityIndex = 0
      @scheduler._appIndex = 0
      run = sinon.stub @scheduler, '_run', ->
      tp = sinon.stub @scheduler, '_tryPriority', ->
        new promise (resolve, reject) -> resolve()
      @scheduler._strategy = [
        ['a', 'b'],
        ['c', 'd'],
        ['e']
      ]
      @scheduler._runStep()
        .then =>
          expect(tp).to.have.been.calledOnce
          expect(tp).to.have.been.calledWith 0, 0
          expect(@scheduler._priorityIndex).to.equal 0
          expect(@scheduler._appIndex).to.equal 1
          process.nextTick ->
            expect(run).to.have.been.calledOnce
            done()

    it 'should reset the app index when current app renders and priority is \
        top level', (done) ->
      @scheduler._priorityIndex = 0
      @scheduler._appIndex = 2
      run = sinon.stub @scheduler, '_run', ->
      tp = sinon.stub @scheduler, '_tryPriority', ->
        new promise (resolve, reject) -> resolve()
      @scheduler._strategy = [
        ['a', 'b', 'c'],
        ['d', 'e'],
        ['e']
      ]
      @scheduler._runStep()
        .then =>
          expect(tp).to.have.been.calledOnce
          expect(tp).to.have.been.calledWith 0, 2
          expect(@scheduler._priorityIndex).to.equal 0
          expect(@scheduler._appIndex).to.equal 0
          process.nextTick ->
            expect(run).to.have.been.calledOnce
            done()

    it 'should reset the app and priority index when current app renders and \
        priority is not top level', (done) ->
      @scheduler._priorityIndex = 1
      @scheduler._appIndex = 1
      run = sinon.stub @scheduler, '_run', ->
      tp = sinon.stub @scheduler, '_tryPriority', ->
        new promise (resolve, reject) -> resolve()
      @scheduler._strategy = [
        ['a', 'b', 'c'],
        ['d', 'e', 'f'],
        ['e']
      ]
      @scheduler._runStep()
        .then =>
          expect(tp).to.have.been.calledOnce
          expect(tp).to.have.been.calledWith 1, 1
          expect(@scheduler._priorityIndex).to.equal 0
          expect(@scheduler._appIndex).to.equal 0
          process.nextTick ->
            expect(run).to.have.been.calledOnce
            done()

    it 'should move to the next priority when the current priority \
        fails', (done) ->
      @scheduler._priorityIndex = 1
      @scheduler._appIndex = 1
      run = sinon.stub @scheduler, '_run', ->
      tp = sinon.stub @scheduler, '_tryPriority', ->
        new promise (resolve, reject) -> reject()
      @scheduler._strategy = [
        ['a', 'b', 'c'],
        ['d', 'e', 'f'],
        ['e']
      ]
      @scheduler._runStep()
        .catch (e) =>
          expect(tp).to.have.been.calledOnce
          expect(tp).to.have.been.calledWith 1, 1
          expect(@scheduler._priorityIndex).to.equal 2
          expect(@scheduler._appIndex).to.equal 0
          process.nextTick =>
            expect(@trackView).to.not.have.been.called
            expect(run).to.have.been.calledOnce
            done()

    it 'should sleep for a while and notify the user when all priority levels \
        fail', (done) ->
      @scheduler._priorityIndex = 2
      @scheduler._appIndex = 1
      run = sinon.stub @scheduler, '_run', ->
      tp = sinon.stub @scheduler, '_tryPriority', ->
        new promise (resolve, reject) -> reject()
      @scheduler._strategy = [
        ['a', 'b', 'c'],
        ['d', 'e', 'f'],
        ['e']
      ]
      @scheduler._runStep()
        .catch (e) =>
          expect(tp).to.have.been.calledOnce
          expect(tp).to.have.been.calledWith 2, 1
          expect(@scheduler._priorityIndex).to.equal 3
          expect(@scheduler._appIndex).to.equal 0
          expect(@trackView).to.have.been.calledOnce
          expect(@trackView).to.have.been.calledWith '__bs'
          expect(run).to.not.have.been.called
          @clock.tick 1000
          expect(run).to.have.been.calledOnce
          done()

  describe '#_run', ->
    it 'should try all apps in priority order when everything fails', (done) ->
      @scheduler._priorityIndex = 0
      @scheduler._appIndex = 0
      run = sinon.stub @scheduler, '_run', =>
        if @scheduler._priorityIndex == 3
          expect(ta).to.have.callCount 7
          expect(ta.args[0]).to.deep.equal ['a']
          expect(ta.args[1]).to.deep.equal ['b']
          expect(ta.args[2]).to.deep.equal ['c']
          expect(ta.args[3]).to.deep.equal ['d']
          expect(ta.args[4]).to.deep.equal ['e']
          expect(ta.args[5]).to.deep.equal ['f']
          expect(ta.args[6]).to.deep.equal ['e']
          done()
          return

        @scheduler._runStep()
          .catch (e) =>
            @clock.tick 1000

      ta = sinon.stub @scheduler, '_tryApp', (app) ->
        new promise (resolve, reject) -> reject()

      @scheduler._strategy = [
        ['a', 'b', 'c'],
        ['d', 'e', 'f'],
        ['e']
      ]
      @scheduler._run()

  describe '#_tryPriority', ->
    it 'should fail when strategy is invalid', (done) ->
      tp = sinon.spy @scheduler, '_tryPriority'
      @scheduler._tryPriority 0, 0
        .catch ->
          expect(tp).to.have.been.calledOnce
          done()

    it 'should fail when priority index is negative', (done) ->
      @scheduler._strategy = [
        ['a', 'b'],
        ['c']
      ]
      tp = sinon.spy @scheduler, '_tryPriority'
      @scheduler._tryPriority -1, 0
        .catch ->
          expect(tp).to.have.been.calledOnce
          done()

    it 'should fail when priority index is out of range', (done) ->
      @scheduler._strategy = [
        ['a', 'b'],
        ['c']
      ]
      tp = sinon.spy @scheduler, '_tryPriority'
      @scheduler._tryPriority 10, 0
        .catch ->
          expect(tp).to.have.been.calledOnce
          done()

    it 'should fail when app index is negative', (done) ->
      @scheduler._strategy = [
        ['a', 'b'],
        ['c']
      ]
      tp = sinon.spy @scheduler, '_tryPriority'
      @scheduler._tryPriority 0, -1
        .catch ->
          expect(tp).to.have.been.calledOnce
          done()

    it 'should fail when app index is out of range', (done) ->
      @scheduler._strategy = [
        ['a', 'b'],
        ['c']
      ]
      tp = sinon.spy @scheduler, '_tryPriority'
      @scheduler._tryPriority 0, 10
        .catch ->
          expect(tp).to.have.been.calledOnce
          done()

    it 'should succeed when _tryPriorityApp succeeds', (done) ->
      @scheduler._strategy = [
        ['a', 'b'],
        ['c']
      ]
      tp = sinon.spy @scheduler, '_tryPriority'
      tpa = sinon.stub @scheduler, '_tryPriorityApp', ->
        new promise (resolve, reject) -> resolve()
      @scheduler._tryPriority 0, 0
        .then ->
          expect(tp).to.have.been.calledOnce
          expect(tpa).to.have.been.calledOnce
          expect(tpa).to.have.been.calledWith ['a', 'b'], 0
          done()

    it 'should try the next app within the same priority when _tryPriorityApp \
        fails', (done) ->
      @scheduler._strategy = [
        ['a', 'b'],
        ['c']
      ]
      tp = sinon.spy @scheduler, '_tryPriority'
      tpa = sinon.stub @scheduler, '_tryPriorityApp', ->
        new promise (resolve, reject) -> reject()
      @scheduler._tryPriority 0, 0
        .catch ->
          expect(tp).to.have.been.calledThrice
          expect(tp.args[0]).to.deep.equal [0, 0]
          expect(tp.args[1]).to.deep.equal [0, 1]
          expect(tp.args[2]).to.deep.equal [0, 2]
          expect(tpa).to.have.been.calledTwice
          expect(tpa.args[0]).to.deep.equal [['a', 'b'], 0]
          expect(tpa.args[1]).to.deep.equal [['a', 'b'], 1]
          done()

  describe '#_tryPriorityApp', ->
    it 'should fail when priority is invalid', (done) ->
      @scheduler._tryPriorityApp undefined, 0
        .catch done

    it 'should fail when app index is negative', (done) ->
      @scheduler._tryPriorityApp ['a'], -3
        .catch done

    it 'should fail when app index is out of range', (done) ->
      @scheduler._tryPriorityApp ['a'], 3
        .catch done

    it 'should fail when tryApp fails', (done) ->
      ta = sinon.stub @scheduler, '_tryApp', ->
        new promise (resolve, reject) -> reject()
      @scheduler._tryPriorityApp ['a'], 0
        .catch ->
          expect(ta).to.have.been.calledOnce
          expect(ta).to.have.been.calledWith 'a'
          done()

    it 'should succeed when tryApp succeeds', (done) ->
      ta = sinon.stub @scheduler, '_tryApp', ->
        new promise (resolve, reject) -> resolve()
      @scheduler._tryPriorityApp ['a', 'b', 'c'], 1
        .then ->
          expect(ta).to.have.been.calledOnce
          expect(ta).to.have.been.calledWith 'b'
          done()

  describe '#_tryApp', ->
    it 'should fail when queue is not okay', (done) ->
      expect(@scheduler._queues).to.not.be.ok
      @scheduler._tryApp 'app'
        .catch done

    it 'should fail when app is unknown', (done) ->
      @scheduler._queues =
        'app':
          __default: []
      @scheduler._tryApp 'unknown'
        .catch done

    it 'should fail when app queues are empty', (done) ->
      @scheduler._queues =
        'app':
          __default: []
          other: []
      @scheduler._tryApp 'app'
        .catch done

    it 'should render a view', (done) ->
      render = sinon.stub @scheduler, '_render', ->
        new promise (resolve, reject) -> resolve()
      view =
        viewId: 'viewId'
        contentId: 'other'
      @scheduler._queues =
        'app':
          __default: []
          other: [view]
      @scheduler._tryApp 'app'
        .then =>
          expect(@scheduler._queues.app.other).to.deep.equal []
          expect(render).to.have.been.calledOnce
          expect(render).to.have.been.calledWith 'app', view
          done()

    it 'should fail when render fails', (done) ->
      render = sinon.stub @scheduler, '_render', ->
        new promise (resolve, reject) -> reject()
      view =
        viewId: 'viewId'
        contentId: 'other'
      @scheduler._queues =
        'app':
          __default: []
          other: [view]
      @scheduler._tryApp 'app'
        .catch =>
          expect(@scheduler._queues.app.other).to.deep.equal []
          expect(render).to.have.been.calledOnce
          expect(render).to.have.been.calledWith 'app', view
          done()

  describe '#_render', ->
    it 'should make a hideRenderShow and render call', (done) ->
      @scheduler._currentApp = 'app2'
      @hideRenderShow.returns new promise (resolve, reject) -> resolve()
      view =
        viewId: 'view-id'
        contentLabel: 'label'
      @scheduler._render 'app1', view
        .then =>
          expect(@hideRenderShow).to.have.been.calledOnce
          expect(@hideRenderShow).to.have.been.calledWith(
            'app2', 'view-id', 'app1')
          expect(@trackView).to.have.been.calledOnce
          expect(@trackView).to.have.been.calledWith 'app1', 'label'
          expect(@scheduler._currentApp).to.equal 'app1'
          done()

    it 'should set the current app when hideRenderShow succeeds', (done) ->
      @scheduler._currentApp = 'app2'
      @hideRenderShow.returns new promise (resolve, reject) -> resolve()
      view =
        viewId: 'view-id'
      @scheduler._render 'app1', view
        .then =>
          expect(@hideRenderShow).to.have.been.calledOnce
          expect(@hideRenderShow).to.have.been.calledWith(
            'app2', 'view-id', 'app1')
          expect(@scheduler._currentApp).to.equal 'app1'
          done()

    it 'should fail when hideRenderShow fails', (done) ->
      @scheduler._currentApp = 'app2'
      @hideRenderShow.returns new promise (resolve, reject) -> reject()
      view =
        viewId: 'view-id'
      @scheduler._render 'app1', view
        .catch =>
          expect(@hideRenderShow).to.have.been.calledOnce
          expect(@hideRenderShow).to.have.been.calledWith(
            'app2', 'view-id', 'app1')
          expect(@scheduler._currentApp).to.equal 'app2'
          done()

  describe '#_prepareApps', ->
    it 'should call prepare() BUFFERED_VIEWS_PER_APP times for each app', ->
      prepare = sinon.stub @scheduler, '_prepare'
      @scheduler._apps =
        app1: true
        app2: true
        app3: true
      @scheduler._activePrepareCalls =
        app1: 0
        app2: 0
        app3: 0

      @scheduler._prepareApps()
      expect(prepare).to.have.callCount 3 * 5

    it 'should make less prepare() calls when there are active calls', ->
      prepare = sinon.stub @scheduler, '_prepare'
      @scheduler._apps =
        app1: true
        app2: true
        app3: true
      @scheduler._activePrepareCalls =
        app1: 0
        app2: 3
        app3: 5

      @scheduler._prepareApps()
      # 5x app1, 2x app2
      expect(prepare).to.have.callCount 7

    it 'should make less prepare() calls when queues are not empty', ->
      prepare = sinon.stub @scheduler, '_prepare'
      @scheduler._apps =
        app1: true
        app2: true
        app3: true
      @scheduler._activePrepareCalls =
        app1: 0
        app2: 3
        app3: 3
      @scheduler._queues =
        app1:
          __default: ['a', 'b']
        app2:
          __default: ['a']
          __other: ['b']
        app3:
          __default: []
          __other: []

      @scheduler._prepareApps()
      # 2x app3, 3x app1
      expect(prepare).to.have.callCount 5
      expect(prepare.args[0][0]).to.equal 'app1'
      expect(prepare.args[1][0]).to.equal 'app1'
      expect(prepare.args[2][0]).to.equal 'app1'
      expect(prepare.args[3][0]).to.equal 'app3'
      expect(prepare.args[4][0]).to.equal 'app3'

  describe '#_prepare', ->
    it 'should make a prepare() call', (done) ->
      @prepare.returns new promise (resolve, reject) -> reject()
      @scheduler._activePrepareCalls =
        app: 1
      @scheduler._prepare 'app'
        .catch =>
          expect(@scheduler._activePrepareCalls['app']).to.equal 1
          expect(@prepare).to.have.been.calledOnce
          expect(@prepare).to.have.been.calledWith 'app'
          done()

      expect(@scheduler._activePrepareCalls['app']).to.equal 2

    it 'should add view to the default queue when contentId is \
        empty', (done) ->
      @scheduler._queues =
        app:
          __default: []
      @scheduler._activePrepareCalls =
        app: 1
      @prepare.returns new promise (resolve, reject) ->
        resolve
          viewId: 'view-id'
      @scheduler._prepare 'app'
        .then =>
          expect(@prepare).to.have.been.calledOnce
          expect(@prepare).to.have.been.calledWith 'app'
          expect(@scheduler._queues.app).to.deep.equal
            __default: [
              {
                viewId: 'view-id',
                contentId: '__default',
                contentLabel: undefined
              }
            ]
          done()

    it 'should create a new queue when contentId is not empty', (done) ->
      @scheduler._queues =
        app:
          __default: []
      @scheduler._activePrepareCalls =
        app: 1
      @prepare.returns new promise (resolve, reject) ->
        resolve
          viewId:       'view-id'
          contentId:    'content-id'
          contentLabel: 'label'
      @scheduler._prepare 'app'
        .then =>
          expect(@prepare).to.have.been.calledOnce
          expect(@prepare).to.have.been.calledWith 'app'
          expect(@scheduler._queues.app).to.deep.equal
            __default: []
            'content-id': [
              {
                viewId:       'view-id',
                contentId:    'content-id',
                contentLabel: 'label'
              }
            ]
          done()

  describe '#_initPriorityQueues', ->
    it 'should initialize app queues', ->
      expect(@scheduler._queues).to.not.be.ok
      @scheduler._apps =
        app1: true
        app2: true
      @scheduler._initPriorityQueues()
      expect(@scheduler._queues).to.deep.equal
        app1:
          __default: []
        app2:
          __default: []
      expect(@scheduler._activePrepareCalls).to.deep.equal
        app1: 0
        app2: 0

  describe '#_extractAppList', ->
    it 'should extract the unique list of apps from a strategy', ->
      strategy = [
        ['app1', 'app2'],
        ['app1', 'app3'],
        ['app4']
      ]
      expect(@scheduler._extractAppList(strategy)).to.deep.equal
        app1: true
        app2: true
        app3: true
        app4: true
