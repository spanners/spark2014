procedure Main with SPARK_Mode is
   type Enum is (A, B);

   procedure Call is null;

   procedure Bar (Value : Enum) is
   begin
      for I in 1 .. 0 loop
         case Value is
            when A  => null;
            when B  => Call; raise Program_Error;
         end case;
         null;
      end loop;
   end Bar;

begin
   null;
end Main;
