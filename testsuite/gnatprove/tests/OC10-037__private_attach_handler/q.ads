package Q with SPARK_Mode is

   protected type PT (X : Integer; Y : Integer; Z : Integer) is
   private
      pragma SPARK_Mode (Off);
      procedure Dummy;
      pragma Attach_Handler (Dummy, 10);
      pragma Interrupt_Priority (98);
   end;

   PO : PT (X => 1, Y => 2, Z => 3);

end;
