#-- vim:sw=2:et
#++
#
# :title: Markov plugin
#
# Author:: Tom Gilbert <tom@linuxbrit.co.uk>
# Copyright:: (C) 2005 Tom Gilbert
#
# Contribute to chat with random phrases built from word sequences learned
# by listening to chat

class MarkovPlugin < Plugin
  Config.register Config::BooleanValue.new('markov.enabled',
    :default => false,
    :desc => "Enable and disable the plugin")
  Config.register Config::IntegerValue.new('markov.probability',
    :default => 25,
    :validate => Proc.new { |v| (0..100).include? v },
    :desc => "Percentage chance of markov plugin chipping in")
  Config.register Config::ArrayValue.new('markov.ignore',
    :default => [],
    :desc => "Hostmasks and channel names markov should NOT learn from (e.g. idiot*!*@*, #privchan).")
  Config.register Config::IntegerValue.new('markov.max_words',
    :default => 50,
    :validate => Proc.new { |v| (0..100).include? v },
    :desc => "Maximum number of words the bot should put in a sentence")
  Config.register Config::IntegerValue.new('markov.learn_delay',
    :default => 0.5,
    :validate => Proc.new { |v| v >= 0 },
    :desc => "Time the learning thread spends sleeping after learning a line. If set to zero, learning from files can be very CPU intensive, but also faster.")

  def initialize
    super
    @registry.set_default([])
    if @registry.has_key?('enabled')
      @bot.config['markov.enabled'] = @registry['enabled']
      @registry.delete('enabled')
    end
    if @registry.has_key?('probability')
      @bot.config['markov.probability'] = @registry['probability']
      @registry.delete('probability')
    end
    if @bot.config['markov.ignore_users']
      debug "moving markov.ignore_users to markov.ignore"
      @bot.config['markov.ignore'] = @bot.config['markov.ignore_users'].dup
      @bot.config.delete('markov.ignore_users'.to_sym)
    end
    @learning_queue = Queue.new
    @learning_thread = Thread.new do
      while s = @learning_queue.pop
        learn_line s
        sleep @bot.config['markov.learn_delay'] unless @bot.config['markov.learn_delay'].zero?
      end
    end
    @learning_thread.priority = -1
  end

  def cleanup
    debug 'closing learning thread'
    @learning_queue.push nil
    @learning_thread.join
    debug 'learning thread closed'
  end

  # if passed a pair, pick a word from the registry using the pair as key.
  # otherwise, pick a word from an given list
  def pick_word(word1, word2=:nonword)
    if word1.kind_of? Array
      wordlist = word1
    else
      wordlist = @registry["#{word1} #{word2}"]
    end
    wordlist.pick_one || :nonword
  end

  def generate_string(word1, word2)
    # limit to max of markov.max_words words
    if word2
      output = "#{word1} #{word2}"
    else
      output = word1.to_s
    end

    if @registry.key? output
      wordlist = @registry[output]
      wordlist.delete(:nonword)
    else
      output.downcase!
      keys = []
      @registry.each_key(output) do |key|
        if key.downcase.include? output
          keys << key
        else
          break
        end
      end
      if keys.empty?
        keys = @registry.keys.select { |k| k.downcase.include? output }
      end
      return nil if keys.empty?
      while key = keys.delete_one
        wordlist = @registry[key]
        wordlist.delete(:nonword)
        unless wordlist.empty?
          output = key
          word1, word2 = output.split
          break
        end
      end
    end

    word3 = pick_word(wordlist)
    return nil if word3 == :nonword

    output << " #{word3}"
    word1, word2 = word2, word3

    (@bot.config['markov.max_words'] - 1).times do
      word3 = pick_word(word1, word2)
      break if word3 == :nonword
      output << " #{word3}"
      word1, word2 = word2, word3
    end
    return output
  end

  def help(plugin, topic="")
    topic, subtopic = topic.split

    case topic
    when "ignore"
      case subtopic
      when "add"
        "markov ignore add <hostmask|channel> => ignore a hostmask or a channel"
      when "list"
        "markov ignore list => show ignored hostmasks and channels"
      when "remove"
        "markov ignore remove <hostmask|channel> => unignore a hostmask or channel"
      else
        "ignore hostmasks or channels -- topics: add, remove, list"
      end
    when "status"
      "markov status => show if markov is enabled, probability and amount of messages in queue for learning"
    when "probability"
      "markov probability [<percent>] => set the % chance of rbot responding to input, or display the current probability"
    when "chat"
      case subtopic
      when "about"
        "markov chat about <word> [<another word>] => talk about <word> or riff on a word pair (if possible)"
      else
        "markov chat => try to say something intelligent"
      end
    else
      "markov plugin: listens to chat to build a markov chain, with which it can (perhaps) attempt to (inanely) contribute to 'discussion'. Sort of.. Will get a *lot* better after listening to a lot of chat. Usage: 'chat' to attempt to say something relevant to the last line of chat, if it can -- help topics: ignore, status, probability, chat, chat about"
    end
  end

  def clean_str(s)
    str = s.dup
    str.gsub!(/^\S+[:,;]/, "")
    str.gsub!(/\s{2,}/, ' ') # fix for two or more spaces
    return str.strip
  end

  def probability?
    return @bot.config['markov.probability']
  end

  def status(m,params)
    if @bot.config['markov.enabled']
      reply = _("markov is currently enabled, %{p}% chance of chipping in") % { :p => probability? }
      l = @learning_queue.length
      reply << (_(", %{l} messages in queue") % {:l => l}) if l > 0
    else
      reply = _("markov is currently disabled")
    end
    m.reply reply
  end

  def ignore?(m=nil)
    return false unless m
    return true if m.address? or m.private?
    @bot.config['markov.ignore'].each do |mask|
      return true if m.channel.downcase == mask.downcase
      return true if m.source.matches?(mask)
    end
    return false
  end

  def ignore(m, params)
    action = params[:action]
    user = params[:option]
    case action
    when 'remove':
      if @bot.config['markov.ignore'].include? user
        s = @bot.config['markov.ignore']
        s.delete user
        @bot.config['ignore'] = s
        m.reply _("%{u} removed") % { :u => user }
      else
        m.reply _("not found in list")
      end
    when 'add':
      if user
        if @bot.config['markov.ignore'].include?(user)
          m.reply _("%{u} already in list") % { :u => user }
        else
          @bot.config['markov.ignore'] = @bot.config['markov.ignore'].push user
          m.reply _("%{u} added to markov ignore list") % { :u => user }
        end
      else
        m.reply _("give the name of a person or channel to ignore")
      end
    when 'list':
      m.reply _("I'm ignoring %{ignored}") % { :ignored => @bot.config['markov.ignore'].join(", ") }
    else
      m.reply _("have markov ignore the input from a hostmask or a channel. usage: markov ignore add <mask or channel>; markov ignore remove <mask or channel>; markov ignore list")
    end
  end

  def enable(m, params)
    @bot.config['markov.enabled'] = true
    m.okay
  end

  def probability(m, params)
    if params[:probability]
      @bot.config['markov.probability'] = params[:probability].to_i
      m.okay
    else
      m.reply _("markov has a %{prob}% chance of chipping in") % { :prob => probability? }
    end
  end

  def disable(m, params)
    @bot.config['markov.enabled'] = false
    m.okay
  end

  def should_talk
    return false unless @bot.config['markov.enabled']
    prob = probability?
    return true if prob > rand(100)
    return false
  end

  def delay
    1 + rand(5)
  end

  def random_markov(m, message)
    return unless should_talk

    word1, word2 = message.split(/\s+/)
    return unless word1 and word2
    line = generate_string(word1, word2)
    return unless line
    # we do nothing if the line we return is just an initial substring
    # of the line we received
    return if message.index(line) == 0
    @bot.timer.add_once(delay) {
      m.reply line, :nick => false, :to => :public
    }
  end

  def chat(m, params)
    line = generate_string(params[:seed1], params[:seed2])
    if line and line != [params[:seed1], params[:seed2]].compact.join(" ")
      m.reply line
    else
      m.reply _("I can't :(")
    end
  end

  def rand_chat(m, params)
    # pick a random pair from the db and go from there
    word1, word2 = :nonword, :nonword
    output = Array.new
    @bot.config['markov.max_words'].times do
      word3 = pick_word(word1, word2)
      break if word3 == :nonword
      output << word3
      word1, word2 = word2, word3
    end
    if output.length > 1
      m.reply output.join(" ")
    else
      m.reply _("I can't :(")
    end
  end

  def learn(*lines)
    lines.each { |l| @learning_queue.push l }
  end

  def unreplied(m)
    return if ignore? m

    # in channel message, the kind we are interested in
    message = clean_str m.plainmessage

    if m.action?
      message = "#{m.sourcenick} #{message}"
    end

    learn message
    random_markov(m, message) unless m.replied?
  end

  def learn_line(message)
    # debug "learning #{message}"
    wordlist = message.split(/\s+/)
    return unless wordlist.length >= 2
    word1, word2 = :nonword, :nonword
    wordlist.each do |word3|
      k = "#{word1} #{word2}"
      @registry[k] = @registry[k].push(word3)
      word1, word2 = word2, word3
    end
    k = "#{word1} #{word2}"
    @registry[k] = @registry[k].push(:nonword)
  end

  # TODO allow learning from URLs
  def learn_from(m, params)
    begin
      path = params[:file]
      file = File.open(path, "r")
      pattern = params[:pattern].empty? ? nil : Regexp.new(params[:pattern].to_s)
    rescue Errno::ENOENT
      m.reply _("no such file")
      return
    end

    if file.eof?
      m.reply _("the file is empty!")
      return
    end

    if params[:testing]
      lines = []
      range = case params[:lines]
      when /^\d+\.\.\d+$/
        Range.new(*params[:lines].split("..").map { |e| e.to_i })
      when /^\d+$/
        Range.new(1, params[:lines].to_i)
      else
        Range.new(1, [@bot.config['send.max_lines'], 3].max)
      end

      file.each do |line|
        next unless file.lineno >= range.begin
        lines << line.chomp
        break if file.lineno == range.end
      end

      lines = lines.map do |l|
        pattern ? l.scan(pattern).to_s : l
      end.reject { |e| e.empty? }

      if pattern
        unless lines.empty?
          m.reply _("example matches for that pattern at lines %{range} include: %{lines}") % {
            :lines => lines.map { |e| Underline+e+Underline }.join(", "),
            :range => range.to_s
          }
        else
          m.reply _("the pattern doesn't match anything at lines %{range}") % {
            :range => range.to_s
          }
        end
      else
        m.reply _("learning from the file without a pattern would learn, for example: ")
        lines.each { |l| m.reply l }
      end

      return
    end

    if pattern
      file.each { |l| learn(l.scan(pattern).to_s) }
    else
      file.each { |l| learn(l.chomp) }
    end

    m.okay
  end
end

plugin = MarkovPlugin.new
plugin.map 'markov ignore :action :option', :action => "ignore"
plugin.map 'markov ignore :action', :action => "ignore"
plugin.map 'markov ignore', :action => "ignore"
plugin.map 'markov enable', :action => "enable"
plugin.map 'markov disable', :action => "disable"
plugin.map 'markov status', :action => "status"
plugin.map 'chat about :seed1 [:seed2]', :action => "chat"
plugin.map 'chat', :action => "rand_chat"
plugin.map 'markov probability [:probability]', :action => "probability",
           :requirements => {:probability => /^\d+%?$/}
plugin.map 'markov learn from :file [:testing [:lines lines]] [using pattern *pattern]', :action => "learn_from", :thread => true,
           :requirements => {
             :testing => /^testing$/,
             :lines   => /^(?:\d+\.\.\d+|\d+)$/ }

plugin.default_auth('ignore', false)
plugin.default_auth('probability', false)
plugin.default_auth('learn', false)

