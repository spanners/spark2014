with Context;
with Response_Types;

package ResponseStream is
   new Context
      (Data_Type => Response_Types.Data_Type);
