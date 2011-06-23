------------------------------------------------------------------------------
--                            IPSTACK COMPONENTS                            --
--           Copyright (C) 2010-2011, Free Software Foundation, Inc.        --
------------------------------------------------------------------------------

--  Callback oriented low level access to the TCP services. At this point,
--  this is a binding to the C implementation of LWIP.

with System;

with AIP.Buffers;
with AIP.Callbacks;
with AIP.IPaddrs;
with AIP.NIF;
with AIP.PCBs;

--# inherit System, AIP.Buffers, AIP.Callbacks, AIP.Checksum, AIP.Config,
--#         AIP.IP, AIP.IPaddrs, AIP.IPH, AIP.NIF, AIP.PCBs, AIP.TCPH,
--#         AIP.Time_Types, AIP.Timers, AIP.Inet, AIP.Conversions;

package AIP.TCP
--# own State;
is

   --------------------
   -- User interface --
   --------------------

   procedure TCP_Init;
   --# global out State;
   --  Initialize internal datastructures. To be called once, before any of
   --  the other subprograms.

   -------------------------
   -- Callbacks interface --
   -------------------------

   type TCP_Event_Kind is
     (TCP_EVENT_ACCEPT,
      TCP_EVENT_CONNECT,
      TCP_EVENT_SENT,
      TCP_EVENT_RECV,
      TCP_EVENT_POLL,
      TCP_EVENT_ABORT);

   type TCP_Event_T is record
      Kind : TCP_Event_Kind;

      Len : AIP.M32_T;
      --  Data length sent and acked (for SENT)

      Buf : Buffers.Buffer_Id;
      --  Data buffer (for RECV)

      Addr : IPaddrs.IPaddr;
      Port : PCBs.Port_T;
      --  Remote socket (for ACCEPT)

      Err : AIP.Err_T;
      --  Reason of abort (for ABORT)
   end record;

   procedure TCP_Event
     (Ev   : TCP_Event_T;
      PCB  : PCBs.PCB_Id;
      Cbid : Callbacks.CBK_Id;
      Err  : out AIP.Err_T);
   --# global in out Buffers.State;
   pragma Import (Ada, TCP_Event, "AIP_tcp_event");
   pragma Weak_External (TCP_Event);
   --  Process TCP event EV, aimed at bound PCB, for which Cbid was registered.
   --  Expected to be provided by the applicative code.

   procedure TCP_Set_Udata (PCB : PCBs.PCB_Id; Udata : System.Address);
   --# global in out State;
   --  Attach Udata to PCB, for later retrieval on event callbacks

   function TCP_Udata (PCB : PCBs.PCB_Id) return System.Address;
   --# global in State;
   --  Retrive callback Udata attached to PCB

   --------------------------------
   -- Setting up TCP connections --
   --------------------------------

   procedure TCP_New (PCB : out PCBs.PCB_Id);
   --# global in out State;
   --  Allocate a new TCP PCB and return the corresponding id, or NOPCB on
   --  allocation failure.

   procedure TCP_Bind
     (PCB        : PCBs.PCB_Id;
      Local_IP   : IPaddrs.IPaddr;
      Local_Port : AIP.U16_T;
      Err        : out AIP.Err_T);
   --# global in out State;
   --  Bind PCB to the provided IP address (possibly IP_ADDR_ANY) and
   --  local PORT number. Return ERR_USE if the requested binding is already
   --  established for another PCB, NOERR otherwise.

   procedure TCP_Listen (PCB : PCBs.PCB_Id; Err : out AIP.Err_T);
   --# global in out State;
   --  Setup PCB to listen for at most Config.TCP_DEFAULT_LISTEN_BACKLOG
   --  simultaneous connection requests and trigger the acceptation callback
   --  on such events.

   procedure TCP_Listen_BL
     (PCB     : PCBs.PCB_Id;
      Backlog : Natural;
      Err     : out AIP.Err_T);
   --# global in out State;
   --  Same as TCP_Listen but with a user-specified backlog size

   procedure On_TCP_Accept
     (PCB : PCBs.PCB_Id;
      Cb  : Callbacks.CBK_Id);
   --# global in out State;
   --  Register CB as the id to pass TCP_Event on TCP_EVENT_ACCEPT for PCB.
   --
   --  TCP_EVENT_ACCEPT triggers when a connection request comes in.
   --
   --  Ev.PCB is the new pcb allocated for the established connection
   --  Ev.Addr/Port designate the connection request origin
   --
   --  The callback typically allocates an application state block, then calls
   --  TCP_Accepted and returns NOERR if all went well. If anything goes
   --  wrong, the callback returns the appropriate error code and AIP aborts
   --  the connection.

   procedure TCP_Accepted (PCB : PCBs.PCB_Id);
   --# global in out State;
   --  Inform the AIP stack that a connection has just been accepted on PCB.
   --  To be called by the TCP_EVENT_ACCEPT callback for proper management of
   --  the listen backlog.

   procedure TCP_Connect
     (PCB  : PCBs.PCB_Id;
      Addr : IPaddrs.IPaddr;
      Port : PCBs.Port_T;
      Cb   : Callbacks.CBK_Id;
      Err  : out AIP.Err_T);
   --# global in out Buffers.State, IP.State, State; in IP.FIB;
   --  Setup PCB to connect to the remote ADDR/PORT and send the initial SYN
   --  segment.  Do not wait for the connection to be entirely setup, but
   --  instead arrange to have CB called when the connection is established or
   --  rejected, as indicated by the ERR argument. This function returns
   --
   --  ERR_MEM if no memory is available for enqueueing the SYN segment,
   --
   --  NOERR   if all went well.

   ----------------------
   -- Sending TCP data --
   ----------------------

   --  TCP data is sent by enqueueing with calls to TCP_Write, and a provided
   --  callback is called when the data has been acknowledged by the remote
   --  host. Care must be taken to respect transmission capacities.

   procedure TCP_Write
     (PCB   : PCBs.PCB_Id;
      Data  : System.Address;
      Len   : AIP.M32_T;
      Copy  : Boolean;
      Push  : Boolean;
      Err   : out AIP.Err_T);
   --# global in out Buffers.State, IP.State, State;
   --  Enqueue DATA/LEN for output through PCB. COPY controls whether data is
   --  copied into AIP's memory before processing, or whether it only gets
   --  referenced from there, in which case clients should not modify it until
   --  it is known to have been acknowledged by the receiver.  PUSH controls
   --  whether PSH should be sent on the last TCP segment sent.
   --
   --  ERR_MEM if the length of the data exceeds the current send buffer size
   --          (as advertised by TCP_Sndbuf) or if the length of the outgoing
   --          segments queue is larger than the configured upper limit. The
   --          application should wait until some of the currently enqueued
   --          data has been successfully received and try again.
   --
   --  ERR_USE if the TCP connection is in an inappropriate state, that is
   --          not one of Established | Close_Wait | Syn_Sent | Syn_Received.
   --
   --  NOERR   if all went well.

   function TCP_Sndbuf (PCB : PCBs.PCB_Id) return AIP.U16_T;
   --# global in State;
   --  Room available for output data queuing.

   procedure On_TCP_Sent
     (PCB : PCBs.PCB_Id;
      Cb  : Callbacks.CBK_Id);
   --# global in out State;
   --  Register CB as the id to pass TCP_Event on TCP_EVENT_SENT for PCB.
   --
   --  TCP_EVENT_SENT triggers when sent data has been acknowledged by
   --  the remote host on PCB.
   --
   --  Ev.Len is the amount data just acknowledged by the remote peer.
   --
   --  NOERR is expected on return.

   ------------------------
   -- Receiving TCP data --
   ------------------------

   --  Data reception is callback based, as everything else.

   procedure On_TCP_Recv
     (PCB : PCBs.PCB_Id;
      Cb  : Callbacks.CBK_Id);
   --# global in out State;
   --  Register CB as the id to pass TCP_Event on TCP_EVENT_RECV for PCB.
   --
   --  TCP_EVENT_RECV triggers when new data or a close-connection request
   --  arrives on PCB.
   --
   --  Ev.Buf designates the packet buffer where the received data resides, or
   --         is NOBUF for a close-connection request.
   --
   --  When all goes well, NOERR is expected on return, and the packet buffer
   --  should be Buffer_Free'd by the callback if it isn't needed by the app
   --  any more. Otherwise, the callback should leave Ev.Buf untouched and
   --  return a descriptive error code.

   procedure TCP_Recved
     (PCB : PCBs.PCB_Id;
      Len : AIP.U16_T);
   --# global in out State;
   --  Inform AIP that LEN bytes of data have been processed and can be
   --  acknowledged.

   -------------
   -- Polling --
   -------------

   --  AIP periodically polls idle connections by calling a callback provided
   --  for this purpose. This can be used to timeout idle connections or as an
   --  opportunity to retry failed TCP_Write attempts.

   procedure On_TCP_Poll
     (PCB : PCBs.PCB_Id;
      Cb  : Callbacks.CBK_Id;
      Ivl : AIP.U16_T);
   --# global in out State;
   --  Register CB as the id to pass TCP_Event on TCP_EVENT_POLL for PCB,
   --  and request that it triggers every IVL ticks from now on.

   ------------------------------
   --  Closing TCP connections --
   ------------------------------

   procedure TCP_Close (PCB : PCBs.PCB_Id; Err : out AIP.Err_T);
   --# global in out Buffers.State, IP.State, State;
   --  Closes the connection held by the provided PCB, which may not be
   --  referenced any more.

   procedure TCP_Drop (PCB : PCBs.PCB_Id);
   --# global in out Buffers.State, IP.State, State; in IP.FIB;
   --  Aborts a connection by sending a RST to the remote host and deletes
   --  the local PCB. This is done when a connection is killed because of
   --  shortage of memory.

   procedure On_TCP_Abort
     (PCB : PCBs.PCB_Id;
      Cb  : Callbacks.CBK_Id);
   --# global in out State;
   --  Register CB as the id to pass TCP_Event on TCP_EVENT_ABORT for PCB.
   --
   --  TCP_EVENT_ABORT triggers when a connection gets aborted because
   --  of some error.
   --
   --  Ev.Err is the aborting error code.

   -----------------------
   -- IPstack interface --
   -----------------------

   procedure TCP_Input (Buf : Buffers.Buffer_Id; Netif : NIF.Netif_Id);
   --# global in out Buffers.State, State, IP.State; in IP.FIB;
   --  Hook for IP.  Process a TCP segment in BUF, and dispatch the TCP payload
   --  to the appropriate user callback. Buf is then free'd.

   ------------
   -- Timers --
   ------------

   procedure TCP_Fast_Timer;
   --# global in out Buffers.State, IP.State, State;
   --  Called every TCP_FAST_INTERVAL (250 ms) and process data previously
   --  "refused" by upper layer (application) and sends delayed ACKs.

   procedure TCP_Slow_Timer;
   --# global in out Buffers.State, IP.State, State;
   --  Called every 500 ms and implements the retransmission timer and the
   --  timer that removes PCBs that have been in TIME-WAIT for enough time. It
   --  also increments various timers such as the inactivity timer in each PCB.

private

   procedure TCP_Free (PCB : PCBs.PCB_Id);
   --# global in out State;
   --  Destroy PCB and mark it as unallocated

   procedure TCP_Output (PCB : PCBs.PCB_Id; Ack_Now : Boolean);
   --# global in out State, IP.State, Buffers.State;
   --  Start output for any pending data or control information on PCB. If
   --  Ack_Now, make sure at least an ACK segment gets sent.

   procedure TCP_Send_Rst
     (Src_IP   : IPaddrs.IPaddr;
      Src_Port : PCBs.Port_T;
      Dst_IP   : IPaddrs.IPaddr;
      Dst_Port : PCBs.Port_T;
      Ack      : Boolean;
      Seq_Num  : AIP.M32_T;
      Ack_Num  : AIP.M32_T;
      Err      : out AIP.Err_T);
   --# global in out IP.State, Buffers.State; in IP.FIB, State;
   --  Send a TCP RST segment

   procedure TCP_Send_Control
     (PCB : PCBs.PCB_Id;
      Syn : Boolean;
      Fin : Boolean;
      Err : out AIP.Err_T);
   --# global in out Buffers.State, IP.State, State;
   --  Send a TCP segment with no payload, just control bits set according
   --  to Syn and Fin. Ack will be set as well unless in Syn_Sent state.

   --  Send_Control shortcuts for common occurrences:

   procedure TCP_Fin (PCB : PCBs.PCB_Id; Err : out AIP.Err_T);
   --# global in out Buffers.State, IP.State, State;
   pragma Inline (TCP_Fin);

   procedure TCP_Syn (PCB : PCBs.PCB_Id; Err : out AIP.Err_T);
   --# global in out Buffers.State, IP.State, State;
   pragma Inline (TCP_Syn);

   procedure TCP_Ack (PCB : PCBs.PCB_Id; Err : out AIP.Err_T);
   --# global in out Buffers.State, IP.State, State;
   pragma Inline (TCP_Ack);

   function Initial_Sequence_Number
     (Local_IP    : IPaddrs.IPaddr;
      Local_Port  : PCBs.Port_T;
      Remote_IP   : IPaddrs.IPaddr;
      Remote_Port : PCBs.Port_T) return AIP.M32_T;
   --# global in State;
   --  Initial sequence number for connection with the given parameters

   --  Sequence number comparisons

   function Seq_Lt (L, R : AIP.M32_T) return Boolean;
   pragma Inline (Seq_Lt);
   --  L < R

   function Seq_Le (L, R : AIP.M32_T) return Boolean;
   pragma Inline (Seq_Le);
   --  L <= R

   function Seq_Range (L, S, R : AIP.M32_T) return Boolean;
   pragma Inline (Seq_Range);
   --  L <= S < R

end AIP.TCP;
