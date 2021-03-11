package body P is
   I : Natural := 0;

   procedure Increment (X : in out Integer)
   is
   begin
      X := X;
   end Increment;

   procedure PP
   is
   begin
      while I < 10 loop
         Increment (I);
      end loop;
   end PP;

end P;
