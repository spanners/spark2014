package body Single_Explicit is

   task body Worker is

      procedure Update
      is
         Tmp : Integer := Mailbox;
      begin
         Mailbox := Tmp + 1;
      end Update;

      X : Integer := Mailbox;
   begin
      loop
         Update;
      end loop;
   end;

end;
