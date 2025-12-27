import core.thread;
import core.time;
import std.stdio;
import std.algorithm;
import utils;

alias Thread = core.thread.Thread;

/**
 * ITrigger - Type-erased trigger interface
 * 
 * All triggers implement this interface to allow type-agnostic scheduling.
 * The scheduler works entirely with ITrigger references.
 */
interface ITrigger
{
	/// Execute the trigger, notifying its linked event with stored payload
	void notify();
}



/**
 * Listener - Wrapper for a delegate and its index
 * 
 * Holds the actual listener delegate and its current position in the event's array.
 * Allocated anywhere (stack, heap, doesn't matter).
 * Event holds pointers to these wrappers.
 */
struct Listener(T)
{
	void delegate(Event!T) listener;  // The actual listener delegate
	size_t index;                      // Current position in event's listener array
}

/**
 * Event - Simple stateful event with typed payload and flat listener pool
 * 
 * Events are notification delivery: fire() calls all listeners.
 * Propagation (hierarchical, conditional, etc.) is caller responsibility.
 * The event object itself is the identity; no string name needed.
 * 
 * Listener removal is O(1) via swap-and-pop with handle-based indexing.
 * 
 * T: Payload type
 */
class Event(T)
{
	alias ListenerPtr = Listener!T*;
	
	protected ListenerPtr[] listeners;  // Array of pointers to listener wrappers
	protected T _payload;
	
	this()
	{
	}
	
	/**
	 * Add a listener callback
	 * Returns a pointer to the listener wrapper for O(1) removal
	 * O(1) amortized
	 */
	ListenerPtr addListener(void delegate(Event!T) listener)
	{
		auto listenerObj = new Listener!T();
		listenerObj.listener = listener;
		listenerObj.index = listeners.length;
		listeners ~= listenerObj;
		return listenerObj;
	}
	
	/**
	 * Remove a listener callback via pointer
	 * O(1) swap-and-pop: swap with last, update displaced listener's index, pop
	 */
	void removeListener(ListenerPtr listenerPtr)
	{
		if (listenerPtr is null)
			return;
		
		size_t idx = listenerPtr.index;
		if (idx >= listeners.length)
			return;
		
		// Swap with last element
		if (idx < listeners.length - 1)
		{
			// Move last to current position
			auto lastListener = listeners[$ - 1];
			listeners[idx] = lastListener;
			lastListener.index = idx;
		}
		
		// Pop the last element
		listeners.length--;
	}

	/**
	 * Fire this event, invoking all listeners
	 */
	void fire()
	{
		foreach (listenerPtr; listeners)
		{
			listenerPtr.listener(this);
		}
	}
	
	/**
	 * Notify listeners with a specific payload
	 * Called by triggers to deliver the payload
	 */
	void notifyWithPayload(T payload)
	{
		this._payload = payload;
		fire();
	}
	
	/**
	 * Get payload (called by listeners)
	 */
	@property T payload() const
	{
		return _payload;
	}
}

/**
 * Trigger - Typed trigger implementing ITrigger
 * 
 * Carries an event and payload, implements type-erased notify() interface.
 * Can be executed immediately or scheduled with TriggerScheduler.
 * T: Payload type passed to listeners
 */
class Trigger(T) : ITrigger
{
	Event!T _targetEvent;
	T payload;
	
	this(Event!T event, T data)
	{
		this._targetEvent = event;
		this.payload = data;
	}
	
	/**
	 * Notify the linked event with this trigger's payload
	 * Implements ITrigger interface for type-agnostic scheduling
	 */
	void notify()
	{
		_targetEvent.notifyWithPayload(payload);
	}
	
	@property Event!T event() { return _targetEvent; }
}



/**
 * ScheduledTrigger - Instance of a trigger scheduled for execution
 * 
 * Non-templated node storing ITrigger reference.
 * Intrusive node in circular doubly-linked list.
 * Works with all trigger types regardless of payload.
 */
struct ScheduledTrigger
{
	ITrigger trigger;
	long executeTimeUs;
	ScheduledTrigger* prev;
	ScheduledTrigger* next;
	
	void cancel()
	{
		TriggerScheduler.removeScheduledTrigger(&this);
	}
}

debug(EventJitter)
{
	/// Jitter metrics collected during trigger execution (debug builds only)
	struct JitterMetrics
	{
		long[] deltas;           // Individual delta measurements (µs)
		long minDelta = long.max;
		long maxDelta = long.min;
		long sumDelta = 0;
		ulong triggersProcessed = 0;
		
		/// Get average delta in microseconds
		long avgDelta() const
		{
			return triggersProcessed > 0 ? sumDelta / triggersProcessed : 0;
		}
		
		/// Reset metrics
		void reset()
		{
			deltas = [];
			minDelta = long.max;
			maxDelta = long.min;
			sumDelta = 0;
			triggersProcessed = 0;
		}
	}
	__gshared JitterMetrics jitterMetrics;
}

/**
 * IScheduler - Polymorphic interface for trigger scheduling
 * 
 * Different implementations provide different execution semantics:
 * - SchedulerHighRes: Fiber + busy-spin (microsecond resolution, high CPU)
 * - SchedulerLowRes: Fiber + system sleep (millisecond resolution, low CPU)
 * - SchedulerPolled: Synchronous polling (frame-rate resolution, zero async overhead)
 */
interface IScheduler
{
	/// Schedule trigger for absolute execution time
	ScheduledTrigger* scheduleTrigger(ITrigger trigger, long executeTimeUs);
	
	/// Schedule trigger with relative delay from now
	ScheduledTrigger* delayTrigger(ITrigger trigger, long delayUs);
	
	/// Remove a scheduled trigger from the timeline
	void removeScheduledTrigger(ScheduledTrigger* node);
	
	/// Execute pending triggers (semantics depend on implementation)
	void exec();
	
	/// Clear all pending triggers and reset state
	void clear();
}

/**
 * SchedulerBase - Shared implementation for all scheduler variants
 * 
 * Provides:
 * - Trigger queue management (circular doubly-linked list)
 * - Jitter metrics collection (debug builds only)
 * - Insertion/removal operations
 * 
 * Subclasses override exec() to define execution strategy.
 */
abstract class SchedulerBase : IScheduler
{
	protected ScheduledTrigger* head;
	
	/// Insert a node into sorted position (ascending by executeTimeUs)
	protected void insertNodeSorted(ScheduledTrigger* node)
	{
		if (head == null)
		{
			// First node
			head = node;
			node.prev = node;
			node.next = node;
			return;
		}
		
		// Walk backwards from tail, comparing with new node's executeTime
		ScheduledTrigger* pos = head.prev;  // Start at tail
		
		// Find insertion point: first node with executeTimeUs <= new node's time
		while (pos != head && pos.executeTimeUs > node.executeTimeUs)
		{
			pos = pos.prev;
		}
		
		// Now pos is either head (new node should be first) or a node with executeTimeUs <= new node's time
		if (pos == head && head.executeTimeUs > node.executeTimeUs)
		{
			// New node is earliest, insert before head
			node.next = head;
			node.prev = head.prev;
			head.prev.next = node;
			head.prev = node;
			head = node;  // New head
		}
		else
		{
			// Insert after pos
			node.next = pos.next;
			node.prev = pos;
			pos.next.prev = node;
			pos.next = node;
		}
	}
	
	/// Remove a scheduled trigger from the timeline
	void removeScheduledTrigger(ScheduledTrigger* node)
	{
		if (node == null || head == null)
			return;
		
		// Check if this is the only node remaining
		if (node.next == node)
		{
			// Only node in list - clear the pool
			head = null;
		}
		else
		{
			// Normal removal: unlink the node from the cycle
			node.prev.next = node.next;
			node.next.prev = node.prev;
			
			// Update head if we removed it
			if (head == node)
			{
				head = node.next;
			}
		}
		
		destroy(node);
	}
	
	/// Clear all pending triggers and reset jitter compensation state
	void clear()
	{
		while (head != null)
		{
			removeScheduledTrigger(head);
		}
	}
	
	/// Execute pending triggers (polymorphic - subclasses define behavior)
	abstract void exec();
}

/**
 * SchedulerHighRes - High-resolution fiber-based scheduler with busy-spin
 * 
 * SEMANTICS:
 * - scheduleTrigger() spawns a fiber on first trigger
 * - Fiber busy-spins for microsecond-level timing resolution
 * - exec() either spawns the fiber or returns immediately (depending on queue state)
 * 
 * PERFORMANCE:
 * - Resolution: Microsecond-level
 * - CPU cost: 100% during scheduled waits
 * - No jitter compensation: external noise is minimal and unpredictable
 */
class SchedulerHighRes : SchedulerBase
{
	/**
	 * Schedule a trigger for execution at an absolute time
	 * 
	 * Fire-and-forget API: caller enqueues, scheduler manages execution.
	 * If queue was empty, spawns a fiber to run the scheduler loop.
	 * Fiber executes all pending triggers, then exits.
	 */
	override ScheduledTrigger* scheduleTrigger(ITrigger trigger, long executeTimeUs)
	{
		bool wasEmpty = (head == null);
		
		ScheduledTrigger* scheduled = new ScheduledTrigger();
		scheduled.trigger = trigger;
		scheduled.executeTimeUs = executeTimeUs;
		scheduled.prev = null;
		scheduled.next = null;
		
		insertNodeSorted(scheduled);
		
		// Spawn fiber if pool was empty (became non-empty after insertion)
		if (wasEmpty)
		{
			Fiber schedulerFiber = new Fiber(() {
				this.execInternal();
			});
			schedulerFiber.call();  // Start immediately
		}
		
		return scheduled;
	}
	
	/**
	 * Delay a trigger for a specified duration from now
	 */
	override ScheduledTrigger* delayTrigger(ITrigger trigger, long delayUs)
	{
		long executeTimeUs = TimeUtils.currTimeUs() + delayUs;
		return scheduleTrigger(trigger, executeTimeUs);
	}
	
	/// Polymorphic exec - HighRes spawns fiber on empty queue
	override void exec()
	{
		if (head != null)
		{
			Fiber schedulerFiber = new Fiber(() {
				this.execInternal();
			});
			schedulerFiber.call();
		}
	}
	
	/// Internal execution loop (runs in fiber context)
	private void execInternal()
	{
		debug(EventJitter)
		{
			long fiberStart = TimeUtils.currTimeUs();
			writeln("  [Fiber started at ", fiberStart, "µs]");
		}
		
		while (head != null)
		{
			long scheduledTimeUs = head.executeTimeUs;
			
			// Yield to scheduled time (busy-spin for microsecond resolution)
			yieldUntilHighRes(scheduledTimeUs);
			
			// Measure actual execution jitter (external system noise: GC, syscalls, etc.)
			long deltaUs = TimeUtils.currTimeUs() - scheduledTimeUs;
			
			// Collect jitter metrics for observation (debug builds only)
			debug(EventJitter)
			{
				jitterMetrics.deltas ~= deltaUs;
				jitterMetrics.minDelta = min(jitterMetrics.minDelta, deltaUs);
				jitterMetrics.maxDelta = max(jitterMetrics.maxDelta, deltaUs);
				jitterMetrics.sumDelta += deltaUs;
				jitterMetrics.triggersProcessed++;
			}
			
			// Execute one trigger
			handleTrigger();
		}
	}
	
	/// Busy-spin yield until absolute target time (microsecond resolution)
	private void yieldUntilHighRes(long targetTimeUs)
	{
		while (TimeUtils.currTimeUs() < targetTimeUs) { }
	}
	
	/// Execute next trigger and remove it from the schedule
	private void handleTrigger()
	{
		if (head == null)
			return;
		
		head.trigger.notify();
		removeScheduledTrigger(head);
	}
}

/**
 * SchedulerLowRes - Low-resolution fiber-based scheduler with pure OS sleep
 * 
 * SEMANTICS:
 * - scheduleTrigger() spawns a fiber on first trigger
 * - Fiber uses OS sleep exclusively (no busy-spin) for energy efficiency
 * - exec() either spawns the fiber or returns immediately
 * 
 * PERFORMANCE:
 * - Resolution: Millisecond-level (~1ms granularity, trades resolution for CPU efficiency)
 * - CPU cost: Negligible during waits (sleeps entirely, no busy-spin)
 * - Deltas: ±450µs around zero, occasional 1-3ms spikes from OS scheduler
 */
class SchedulerLowRes : SchedulerBase
{
	override ScheduledTrigger* scheduleTrigger(ITrigger trigger, long executeTimeUs)
	{
		bool wasEmpty = (head == null);
		
		ScheduledTrigger* scheduled = new ScheduledTrigger();
		scheduled.trigger = trigger;
		scheduled.executeTimeUs = executeTimeUs;
		scheduled.prev = null;
		scheduled.next = null;
		
		insertNodeSorted(scheduled);
		
		if (wasEmpty)
		{
			Fiber schedulerFiber = new Fiber(() {
				this.execInternal();
			});
			schedulerFiber.call();
		}
		
		return scheduled;
	}
	
	override ScheduledTrigger* delayTrigger(ITrigger trigger, long delayUs)
	{
		long executeTimeUs = TimeUtils.currTimeUs() + delayUs;
		return scheduleTrigger(trigger, executeTimeUs);
	}
	
	override void exec()
	{
		if (head != null)
		{
			Fiber schedulerFiber = new Fiber(() {
				this.execInternal();
			});
			schedulerFiber.call();
		}
	}
	
	private void execInternal()
	{
		debug(EventJitter)
		{
			long fiberStart = TimeUtils.currTimeUs();
			writeln("  [LowRes Fiber started at ", fiberStart, "µs]");
		}
		
		while (head != null)
		{
			long scheduledTimeUs = head.executeTimeUs;
			long executeTimeUs = TimeUtils.currTimeUs();
			long delayUs = scheduledTimeUs - executeTimeUs;
			
			// Sleep for the full delay (OS sleep resolution, no busy-spin)
			// LowRes accepts millisecond-level resolution for negligible CPU cost
			long sleepMs = (delayUs + 500) / 1000;  // Round to nearest millisecond
			if (sleepMs > 0)
			{
				Thread.sleep(dur!"msecs"(sleepMs));
			}
			
			// Measure actual execution jitter (external system noise)
			long deltaUs = TimeUtils.currTimeUs() - scheduledTimeUs;
			
			debug(EventJitter)
			{
				jitterMetrics.deltas ~= deltaUs;
				jitterMetrics.minDelta = min(jitterMetrics.minDelta, deltaUs);
				jitterMetrics.maxDelta = max(jitterMetrics.maxDelta, deltaUs);
				jitterMetrics.sumDelta += deltaUs;
				jitterMetrics.triggersProcessed++;
			}
			
			handleTrigger();
		}
	}
	
	private void handleTrigger()
	{
		if (head == null)
			return;
		
		head.trigger.notify();
		removeScheduledTrigger(head);
	}
}

/**
 * SchedulerPolled - Synchronous polling scheduler
 * 
 * SEMANTICS:
 * - scheduleTrigger() simply enqueues (no fiber spawning)
 * - exec() processes all ready triggers synchronously in caller's context
 * - Caller must invoke exec() regularly (each game loop frame)
 * 
 * PERFORMANCE:
 * - Precision: Frame-rate limited (16ms @ 60fps)
 * - CPU cost: Negligible (amortized into frame loop)
 * - Synchronous: No async overhead
 */
class SchedulerPolled : SchedulerBase
{
	override ScheduledTrigger* scheduleTrigger(ITrigger trigger, long executeTimeUs)
	{
		ScheduledTrigger* scheduled = new ScheduledTrigger();
		scheduled.trigger = trigger;
		scheduled.executeTimeUs = executeTimeUs;
		scheduled.prev = null;
		scheduled.next = null;
		
		insertNodeSorted(scheduled);
		return scheduled;
	}
	
	override ScheduledTrigger* delayTrigger(ITrigger trigger, long delayUs)
	{
		long executeTimeUs = TimeUtils.currTimeUs() + delayUs;
		return scheduleTrigger(trigger, executeTimeUs);
	}
	
	/// Synchronously process all ready triggers
	override void exec()
	{
		long currentTimeUs = TimeUtils.currTimeUs();
		
		while (head != null && head.executeTimeUs <= currentTimeUs)
		{
			head.trigger.notify();
			removeScheduledTrigger(head);
		}
	}
}

/**
 * TriggerScheduler - Backwards compatibility wrapper
 * 
 * Legacy code can still use TriggerScheduler.scheduleTrigger() etc. via a global instance.
 * New code should instantiate SchedulerHighRes, SchedulerLowRes, or SchedulerPolled directly.
 */
static class TriggerScheduler
{
	private static IScheduler _globalScheduler;
	
	/// Initialize with a specific scheduler variant (default: HighRes)
	static void init(IScheduler scheduler = null)
	{
		_globalScheduler = scheduler is null ? new SchedulerHighRes() : scheduler;
	}
	
	/// Get the current global scheduler
	static IScheduler get()
	{
		if (_globalScheduler is null)
			init();
		return _globalScheduler;
	}
	
	/// Delegate to global scheduler
	static ScheduledTrigger* scheduleTrigger(ITrigger trigger, long executeTimeUs)
	{
		return get().scheduleTrigger(trigger, executeTimeUs);
	}
	
	static ScheduledTrigger* delayTrigger(ITrigger trigger, long delayUs)
	{
		return get().delayTrigger(trigger, delayUs);
	}
	
	static void removeScheduledTrigger(ScheduledTrigger* node)
	{
		get().removeScheduledTrigger(node);
	}
	
	static void clear()
	{
		get().clear();
	}
}
