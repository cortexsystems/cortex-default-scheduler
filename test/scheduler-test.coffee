require './test-case'
expect    = require('chai').expect
sinon     = require 'sinon'
promise   = require 'promise'

DefaultScheduler = require '../src/scheduler'

describe 'Scheduler', ->
  beforeEach ->
    @render = sinon.stub()
    @showHide = sinon.stub()
    @prepare = sinon.stub()
    @api =
      scheduler:
        render:   @render
        prepare:  @prepare
        showHide: @showHide
    @scheduler = new DefaultScheduler()
    @scheduler._api = @api

  describe '#_runStep', ->
    it 'should throw when strategy is invalid', ->
      expect(@scheduler._strategy).to.not.be.ok
      expect(=> @scheduler._runStep()).to.throw
      @scheduler._strategy = []
      expect(=> @scheduler._runStep()).to.throw

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
          process.nextTick ->
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

      ta = sinon.stub @scheduler, '_tryApp', (app) ->
        console.log "Trying app #{app}"
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
      dv = sinon.stub @scheduler, '_discardView'
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
        .then ->
          expect(dv).to.have.been.calledOnce
          expect(dv).to.have.been.calledWith 'app', view
          expect(render).to.have.been.calledOnce
          expect(render).to.have.been.calledWith 'app', view
          done()

    it 'should fail when render fails', (done) ->
      dv = sinon.stub @scheduler, '_discardView'
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
        .catch ->
          expect(dv).to.not.have.been.called
          expect(render).to.have.been.calledOnce
          expect(render).to.have.been.calledWith 'app', view
          done()

  describe '#_render', ->
    it 'should make a showHide and render call', (done) ->
      @scheduler._currentApp = 'app2'
      @showHide.returns new promise (resolve, reject) -> resolve()
      @render.returns new promise (resolve, reject) -> resolve()
      view =
        viewId: 'view-id'
      @scheduler._render 'app1', view
        .then =>
          expect(@showHide).to.have.been.calledOnce
          expect(@showHide).to.have.been.calledWith 'app1', 'app2'
          expect(@render).to.have.been.calledOnce
          expect(@render).to.have.been.calledWith 'app1', 'view-id'
          expect(@scheduler._currentApp).to.equal 'app1'
          done()

    it 'should discard the view when render fails', (done) ->
      @scheduler._currentApp = 'app2'
      dv = sinon.stub @scheduler, '_discardView'
      @showHide.returns new promise (resolve, reject) -> resolve()
      @render.returns new promise (resolve, reject) -> reject()
      view =
        viewId: 'view-id'
      @scheduler._render 'app1', view
        .catch =>
          expect(@showHide).to.have.been.calledOnce
          expect(@showHide).to.have.been.calledWith 'app1', 'app2'
          expect(@render).to.have.been.calledOnce
          expect(@render).to.have.been.calledWith 'app1', 'view-id'
          expect(@scheduler._currentApp).to.equal 'app1'
          expect(dv).to.have.been.calledOnce
          expect(dv).to.have.been.calledWith 'app1', view
          done()

    it 'should set the current app when showHide succeeds', (done) ->
      @scheduler._currentApp = 'app2'
      @showHide.returns new promise (resolve, reject) -> resolve()
      @render.returns new promise (resolve, reject) -> reject()
      view =
        viewId: 'view-id'
      @scheduler._render 'app1', view
        .catch =>
          expect(@showHide).to.have.been.calledOnce
          expect(@showHide).to.have.been.calledWith 'app1', 'app2'
          expect(@render).to.have.been.calledOnce
          expect(@render).to.have.been.calledWith 'app1', 'view-id'
          expect(@scheduler._currentApp).to.equal 'app1'
          done()

    it 'should fail when showHide fails', (done) ->
      @scheduler._currentApp = 'app2'
      dv = sinon.stub @scheduler, '_discardView'
      @showHide.returns new promise (resolve, reject) -> reject()
      @render.returns new promise (resolve, reject) -> resolve()
      view =
        viewId: 'view-id'
      @scheduler._render 'app1', view
        .catch =>
          expect(dv).to.not.have.been.called
          expect(@showHide).to.have.been.calledOnce
          expect(@showHide).to.have.been.calledWith 'app1', 'app2'
          expect(@render).to.have.been.calledOnce
          expect(@render).to.have.been.calledWith 'app1', 'view-id'
          expect(@scheduler._currentApp).to.equal 'app2'
          done()

    it 'should fail when both api calls fail', (done) ->
      @scheduler._currentApp = 'app2'
      @showHide.returns new promise (resolve, reject) -> reject()
      @render.returns new promise (resolve, reject) -> reject()
      view =
        viewId: 'view-id'
      @scheduler._render 'app1', view
        .catch =>
          expect(@showHide).to.have.been.calledOnce
          expect(@showHide).to.have.been.calledWith 'app1', 'app2'
          expect(@render).to.have.been.calledOnce
          expect(@render).to.have.been.calledWith 'app1', 'view-id'
          expect(@scheduler._currentApp).to.equal 'app2'
          done()

  describe '#_discardView', ->
    it 'should discard the view', ->
      view1 =
        viewId: 'view1'
        contentId: 'other'
      view2 =
        viewId: 'view2'
        contentId: 'other'
      view3 =
        viewId: 'view3'
        contentId: '__default'
      @scheduler._queues =
        app:
          __default: [view3]
          other: [view1, view2]

      @scheduler._discardView 'app', undefined
      expect(@scheduler._queues).to.deep.equal
        app:
          __default: [view3]
          other: [view1, view2]

      @scheduler._discardView 'app', view1
      expect(@scheduler._queues).to.deep.equal
        app:
          __default: [view3]
          other: [view2]

      @scheduler._discardView 'app', view2
      expect(@scheduler._queues).to.deep.equal
        app:
          __default: [view3]
          other: []

      @scheduler._discardView 'app', view3
      expect(@scheduler._queues).to.deep.equal
        app:
          __default: []
          other: []

      @scheduler._discardView 'app', view3
      expect(@scheduler._queues).to.deep.equal
        app:
          __default: []
          other: []

    it 'should call prepare() for a new view after a discard', ->
      prepare = sinon.stub @scheduler, '_prepare'
      view =
        viewId: 'view-id'
        contentId: '__default'
      @scheduler._queues =
        app:
          __default: [view]
      @scheduler._discardView 'app', view
      expect(@scheduler._queues).to.deep.equal
        app:
          __default: []
      expect(prepare).to.have.been.calledOnce
      expect(prepare).to.have.been.calledWith 'app'

  describe '#_prepareApps', ->
    it 'should call prepare() BUFFERED_VIEWS_PER_APP times for each app', ->
      prepare = sinon.stub @scheduler, '_prepare'
      @scheduler._apps =
        'app1': true
        'app2': true
        'app3': true

      @scheduler._prepareApps()
      expect(prepare).to.have.callCount 3 * 5

  describe '#_prepare', ->
    it 'should make a prepare() call', (done) ->
      @prepare.returns new promise (resolve, reject) -> reject()
      @scheduler._prepare 'app'
        .catch =>
          expect(@prepare).to.have.been.calledOnce
          expect(@prepare).to.have.been.calledWith 'app'
          done()

    it 'should add view to the default queue when contentId is \
        empty', (done) ->
      @scheduler._queues =
        'app':
          __default: []
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
        'app':
          __default: []
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
