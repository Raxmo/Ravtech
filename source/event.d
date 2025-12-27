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
 * Can be executed immediately or scheduled with an IScheduler instance.
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
 * Supported implementations:
 * - SchedulerLowRes: Async fiber + OS sleep (default)
 */
interface IScheduler
{
	/// Schedule trigger for absolute execution time
	ScheduledTrigger* scheduleTrigger(ITrigger trigger, long executeTimeUs);
	
	/// Schedule trigger with relative delay from now
	ScheduledTrigger* delayTrigger(ITrigger trigger, long delayUs);
	
	/// Remove a scheduled trigger from the timeline
	void removeScheduledTrigger(ScheduledTrigger* node);
	
	/// Clear all pending triggers and reset state
	void clear();
}

/**
 * SchedulerLowRes - Event scheduler with sleeping sleep-and-execute semantics
 * 
 * DESIGN: Synchronous execution with OS sleep (no fibers, no async)
 * - scheduleTrigger() enqueues trigger and executes all ready ones immediately
 * - Sleeps (blocks thread) until each trigger's scheduled time arrives
 * - poll() executes ready triggers without sleeping (frame-aligned mode)
 * 
 * EXECUTION MODES:
 * 1. Blocking sleep (scheduleTrigger):
 *    - Thread.sleep() until scheduled time
 *    - Blocking but CPU-efficient (OS scheduler handles sleep)
 *    - Resolution: Millisecond-level (~1ms from rounding)
 * 
 * 2. Frame polling (poll):
 *    - Executes only ready triggers (no sleep)
 *    - Caller invokes once per frame
 *    - Zero sleep overhead, frame-rate limited
 * 
 * QUEUE: Circular doubly-linked list sorted by executeTimeUs (O(1) ops)
 * JITTER: Debug mode collects delta measurements (zero production overhead)
 */
class SchedulerLowRes : IScheduler
{
	protected ScheduledTrigger* head;
	
	/// Insert a node into sorted position (ascending by executeTimeUs)
	private void insertNodeSorted(ScheduledTrigger* node)
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
	
	/// Schedule trigger for execution (enqueue and execute ready triggers)
	ScheduledTrigger* scheduleTrigger(ITrigger trigger, long executeTimeUs)
	{
		ScheduledTrigger* scheduled = new ScheduledTrigger();
		scheduled.trigger = trigger;
		scheduled.executeTimeUs = executeTimeUs;
		scheduled.prev = null;
		scheduled.next = null;
		
		insertNodeSorted(scheduled);
		
		// Execute all ready triggers immediately
		executeReady();
		
		return scheduled;
	}
	
	/// Schedule trigger with relative delay from now
	ScheduledTrigger* delayTrigger(ITrigger trigger, long delayUs)
	{
		long executeTimeUs = TimeUtils.currTimeUs() + delayUs;
		return scheduleTrigger(trigger, executeTimeUs);
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
	
	/// Clear all pending triggers and reset state
	void clear()
	{
		while (head != null)
		{
			removeScheduledTrigger(head);
		}
	}
	
	/// Execute all ready triggers (sleep if future-scheduled)
	private void executeReady()
	{
		while (head != null)
		{
			long delayUs = head.executeTimeUs - TimeUtils.currTimeUs();
			
			// Sleep for the full delay (OS sleep resolution, no busy-spin)
			// LowRes accepts millisecond-level resolution for negligible CPU cost
			long sleepMs = (delayUs + 500) / 1000;  // Round to nearest millisecond
			if (sleepMs > 0)
			{
				Thread.sleep(dur!"msecs"(sleepMs));
			}
			
			debug(EventJitter)
			{
				// Measure actual execution jitter (external system noise)
				long deltaUs = TimeUtils.currTimeUs() - head.executeTimeUs;
				jitterMetrics.deltas ~= deltaUs;
				jitterMetrics.minDelta = min(jitterMetrics.minDelta, deltaUs);
				jitterMetrics.maxDelta = max(jitterMetrics.maxDelta, deltaUs);
				jitterMetrics.sumDelta += deltaUs;
				jitterMetrics.triggersProcessed++;
			}
			
			// Execute trigger and remove from queue
			head.trigger.notify();
			removeScheduledTrigger(head);
		}
	}
	
	/// Poll for ready triggers synchronously (frame-aligned mode)
	/// Call this once per frame in your game loop
	void poll()
	{
		long currentTimeUs = TimeUtils.currTimeUs();
		
		while (head != null && head.executeTimeUs <= currentTimeUs)
		{
			head.trigger.notify();
			removeScheduledTrigger(head);
		}
	}
}
