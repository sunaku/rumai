require 'irb'

module IRB
  ##
  # Starts an IRB session *inside* the given object.
  #
  # This code was adapted from a snippet on Massimiliano Mirra's website:
  # http://www.therubymine.com/articles/2007/01/29/programmare-dallinterno
  #
  def self.start_session context
    IRB.setup nil

    env = IRB::WorkSpace.new(context)
    irb = IRB::Irb.new(env)
    IRB.conf[:MAIN_CONTEXT] = irb.context

    catch :IRB_EXIT do
      irb.eval_input
    end
  end
end
