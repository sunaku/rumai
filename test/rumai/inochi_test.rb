require 'rumai/inochi'

unless defined? Rumai::INOCHI
  fail "Rumai module must be established by Inochi"
end

Rumai::INOCHI.each do |param, value|
  const = param.to_s.upcase

  unless Rumai.const_defined? const
    fail "Rumai::#{const} must be established by Inochi"
  end

  unless Rumai.const_get(const) == value
    fail "Rumai::#{const} is not what Inochi established"
  end
end
